import Darwin
import Foundation
import OSLog

/// A USB-only RFB client that completes the protocol handshake and then sends
/// input events. It deliberately has no API or code path for framebuffer
/// requests, so video remains on the independent AVFoundation capture path.
final class RFBInputClient: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "local.iphone.usbconsole",
        category: "RFBMicrophone"
    )

    enum ProtocolVersion: String, Equatable, Sendable {
        case v3_3 = "3.3"
        case v3_7 = "3.7"
        case v3_8 = "3.8"

        fileprivate var banner: [UInt8] {
            switch self {
            case .v3_3: return Array("RFB 003.003\n".utf8)
            case .v3_7: return Array("RFB 003.007\n".utf8)
            case .v3_8: return Array("RFB 003.008\n".utf8)
            }
        }
    }

    struct ServerInfo: Equatable, Sendable {
        let protocolVersion: ProtocolVersion
        let framebufferWidth: UInt16
        let framebufferHeight: UInt16
    }

    enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected(ServerInfo)
    }

    enum ClientError: Error, LocalizedError, Equatable, Sendable {
        case noUSBDevice
        case targetUSBDeviceNotConnected
        case usbMuxUnavailable
        case usbConnectionFailed
        case unsupportedProtocol
        case classicVNCAuthenticationUnavailable
        case authenticationFailed
        case handshakeTimedOut
        case peerDisconnected
        case malformedServerData
        case unexpectedServerMessage
        case inputWriteFailed
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noUSBDevice:
                return "未找到通过 USB 连接的 iPhone。"
            case .targetUSBDeviceNotConnected:
                return "指定的 iPhone 尚未通过 USB 连接。"
            case .usbMuxUnavailable:
                return "无法连接本机 usbmuxd 服务。"
            case .usbConnectionFailed:
                return "无法通过 USB 连接 iPhone 上的 TrollVNC 端口。"
            case .unsupportedProtocol:
                return "TrollVNC 返回了不支持的 RFB 协议版本。"
            case .classicVNCAuthenticationUnavailable:
                return "服务端未提供 Classic VNCAuth 鉴权。"
            case .authenticationFailed:
                return "VNC 密码验证失败。"
            case .handshakeTimedOut:
                return "VNC 握手超时。"
            case .peerDisconnected:
                return "iPhone 上的 VNC 连接已断开。"
            case .malformedServerData:
                return "VNC 服务端返回了无效数据。"
            case .unexpectedServerMessage:
                return "VNC 服务端发送了输入专用连接不应接收的消息。"
            case .inputWriteFailed:
                return "向 iPhone 发送控制输入失败。"
            case .cancelled:
                return "连接已取消。"
            }
        }
    }

    typealias ConnectCompletion = (Result<ServerInfo, Error>) -> Void

    var onStateChange: ((State) -> Void)? {
        get {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            return stateCallback
        }
        set {
            lifecycleLock.lock()
            stateCallback = newValue
            lifecycleLock.unlock()
        }
    }

    var onError: ((ClientError) -> Void)? {
        get {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            return errorCallback
        }
        set {
            lifecycleLock.lock()
            errorCallback = newValue
            lifecycleLock.unlock()
        }
    }

    var state: State {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return storedState
    }

    var isConnected: Bool {
        if case .connected = state {
            return true
        }
        return false
    }

    private static let trollVNCPort: UInt16 = 5901
    private static let handshakeTimeoutNanoseconds: UInt64 = 15_000_000_000
    private static let messageTimeoutNanoseconds: UInt64 = 3_000_000_000
    private static let microphoneMessageTimeoutNanoseconds: UInt64 = 5_000_000
    // AVAudioEngine delivers macOS input taps in bursts of roughly 100 ms even
    // when a smaller buffer is requested. One callback therefore packetizes to
    // five 20 ms RFB messages before ioQueue can drain any of them. Keep a
    // bounded 240 ms queue so one burst plus normal scheduler jitter cannot be
    // mistaken for a stalled USB transport.
    private static let maximumPendingMicrophonePackets = 12
    private static let serverPayloadTimeoutNanoseconds: UInt64 = 5_000_000_000
    private static let maximumServerNameLength: UInt32 = 1_048_576
    private static let maximumServerTextLength: UInt32 = 1_048_576
    private static let maximumFailureReasonLength: UInt32 = 65_536

    private let ioQueue = DispatchQueue(
        label: "local.iphone.usbconsole.rfb-input",
        qos: .userInteractive
    )
    private let monitorQueue = DispatchQueue(
        label: "local.iphone.usbconsole.rfb-monitor",
        qos: .userInitiated
    )
    private let lifecycleLock = NSLock()
    private let microphoneSendLock = NSLock()
    private let targetUDID: String

    private struct MicrophoneOutboundState {
        let transport: RFBTransport
        let connectionToken: UInt64
        let streamID: UInt32
        let generation: UInt64
        var acceptingPackets: Bool
        var pendingPackets: Int
    }

    private enum MicrophonePacketReservation {
        case accepted(generation: UInt64)
        case overflow(pendingPackets: Int)
        case rejected(reason: String)
    }

    private var generation: UInt64 = 0
    private var activeTransport: RFBTransport?
    private var transportIsReady = false
    private var storedState: State = .disconnected
    private var stateCallback: ((State) -> Void)?
    private var errorCallback: ((ClientError) -> Void)?
    private var microphoneSendGeneration: UInt64 = 0
    private var microphoneOutboundState: MicrophoneOutboundState?

    init(targetUDID: String) {
        self.targetUDID = targetUDID
    }

    deinit {
        lifecycleLock.lock()
        let transport = activeTransport
        activeTransport = nil
        transportIsReady = false
        generation &+= 1
        lifecycleLock.unlock()
        invalidateAllMicrophoneSends()
        transport?.requestCancellation()
    }

    /// Opens an RFB input channel to the configured physical USB device.
    /// The password is only retained by the in-flight handshake closure and its
    /// temporary UTF-8 byte buffer is cleared as soon as the handshake ends.
    func connect(password: String, completion: @escaping ConnectCompletion) {
        lifecycleLock.lock()
        generation &+= 1
        let token = generation
        let previousTransport = activeTransport
        let previousTransportWasReady = transportIsReady
        activeTransport = nil
        transportIsReady = false
        storedState = .connecting
        lifecycleLock.unlock()
        invalidateAllMicrophoneSends()

        if let previousTransport {
            if previousTransportWasReady {
                ioQueue.async { [weak self, previousTransport] in
                    if let self {
                        try? self.releaseTrackedInputs(on: previousTransport)
                    }
                    previousTransport.requestCancellation()
                }
            } else {
                previousTransport.requestCancellation()
            }
        }
        notifyState(.connecting, token: token)

        ioQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.failure(ClientError.cancelled))
                }
                return
            }
            self.performConnect(password: password, token: token, completion: completion)
        }
    }

    /// Gracefully releases any active buttons/keys when possible, then tears
    /// down the socket. A handshake that has not completed is cancelled at once.
    func disconnect() {
        lifecycleLock.lock()
        generation &+= 1
        let notificationToken = generation
        let transport = activeTransport
        let wasReady = transportIsReady
        activeTransport = nil
        transportIsReady = false
        storedState = .disconnected
        lifecycleLock.unlock()
        invalidateAllMicrophoneSends()

        notifyState(.disconnected, token: notificationToken)

        guard let transport else { return }
        if wasReady {
            ioQueue.async { [weak self, transport] in
                if let self {
                    try? self.releaseTrackedInputs(on: transport)
                }
                transport.requestCancellation()
            }
        } else {
            transport.requestCancellation()
        }
    }

    /// Enqueues one standard RFB PointerEvent (message type 5).
    func sendPointer(mask: UInt8, x: UInt16, y: UInt16) {
        guard let context = currentReadyContext() else { return }
        ioQueue.async { [weak self, transport = context.transport] in
            guard let self, self.isCurrentReady(transport: transport, token: context.token) else {
                return
            }
            do {
                try self.writeMessage(
                    Self.pointerMessage(mask: mask, x: x, y: y),
                    to: transport
                )
                transport.lastPointerX = x
                transport.lastPointerY = y
                transport.lastPointerMask = mask
            } catch let error as ClientError {
                self.failActiveConnection(transport: transport, token: context.token, error: error)
            } catch {
                self.failActiveConnection(
                    transport: transport,
                    token: context.token,
                    error: .inputWriteFailed
                )
            }
        }
    }

    /// Enqueues one standard RFB KeyEvent (message type 4) using an X11 keysym.
    func sendKey(down: Bool, keysym: UInt32) {
        guard let context = currentReadyContext() else { return }
        ioQueue.async { [weak self, transport = context.transport] in
            guard let self, self.isCurrentReady(transport: transport, token: context.token) else {
                return
            }
            do {
                try self.writeMessage(Self.keyMessage(down: down, keysym: keysym), to: transport)
                if down {
                    transport.pressedKeysyms.insert(keysym)
                } else {
                    transport.pressedKeysyms.remove(keysym)
                }
            } catch let error as ClientError {
                self.failActiveConnection(transport: transport, token: context.token, error: error)
            } catch {
                self.failActiveConnection(
                    transport: transport,
                    token: context.token,
                    error: .inputWriteFailed
                )
            }
        }
    }

    /// Releases the pointer and every keysym whose successful down event has
    /// not yet been paired with a successful up event.
    func releaseAllInputs() {
        guard let context = currentReadyContext() else { return }
        ioQueue.async { [weak self, transport = context.transport] in
            guard let self, self.isCurrentReady(transport: transport, token: context.token) else {
                return
            }
            do {
                try self.releaseTrackedInputs(on: transport)
            } catch let error as ClientError {
                self.failActiveConnection(transport: transport, token: context.token, error: error)
            } catch {
                self.failActiveConnection(
                    transport: transport,
                    token: context.token,
                    error: .inputWriteFailed
                )
            }
        }
    }

    /// Starts one explicit microphone-replacement stream over the already
    /// authenticated RFB channel. The payload is carried in ClientCutText so it
    /// inherits the existing USB-only VNC authentication and opens no new port.
    @discardableResult
    func beginMicrophoneStream(streamID: UInt32, timestampMicroseconds: UInt64) -> Bool {
        guard streamID != 0 else {
            Self.logger.error("Microphone START rejected because stream ID is zero")
            return false
        }
        guard let context = currentReadyContext() else {
            Self.logger.error("Microphone START rejected because RFB is not ready")
            return false
        }
        guard let sendGeneration = beginMicrophoneSendState(
            transport: context.transport,
            connectionToken: context.token,
            streamID: streamID
        ) else {
            Self.logger.error("Microphone START rejected because an outbound stream already exists")
            return false
        }
        Self.logger.info(
            "Microphone START queued stream=\(streamID, privacy: .public) generation=\(sendGeneration, privacy: .public)"
        )
        ioQueue.async { [weak self, transport = context.transport] in
            guard let self,
                  self.isCurrentReady(transport: transport, token: context.token),
                  self.isMicrophoneSendStateCurrent(
                      transport: transport,
                      connectionToken: context.token,
                      streamID: streamID,
                      generation: sendGeneration,
                      requireAccepting: true
                  ) else {
                self?.invalidateMicrophoneSendState(
                    transport: transport,
                    connectionToken: context.token,
                    streamID: streamID
                )
                Self.logger.error(
                    "Microphone START cancelled before write stream=\(streamID, privacy: .public)"
                )
                return
            }
            do {
                try self.writeMessage(
                    Self.microphoneMessage(
                        flags: 0x01,
                        streamID: streamID,
                        packetSequence: 0,
                        timestampMicroseconds: timestampMicroseconds,
                        sampleCount: 0,
                        pcmData: Data()
                    ),
                    to: transport
                )
                transport.activeMicrophoneStreamID = streamID
                Self.logger.info(
                    "Microphone START written stream=\(streamID, privacy: .public)"
                )
            } catch let error as ClientError {
                Self.logger.error(
                    "Microphone START write failed stream=\(streamID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                self.invalidateMicrophoneSendState(
                    transport: transport,
                    connectionToken: context.token,
                    streamID: streamID
                )
                self.failActiveConnection(transport: transport, token: context.token, error: error)
            } catch {
                Self.logger.error(
                    "Microphone START write failed stream=\(streamID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                self.invalidateMicrophoneSendState(
                    transport: transport,
                    connectionToken: context.token,
                    streamID: streamID
                )
                self.failActiveConnection(transport: transport, token: context.token, error: .inputWriteFailed)
            }
        }
        return true
    }

    @discardableResult
    func sendMicrophonePCM(
        streamID: UInt32,
        packetSequence: UInt32,
        timestampMicroseconds: UInt64,
        sampleCount: UInt16,
        pcmData: Data
    ) -> Bool {
        guard streamID != 0,
              sampleCount > 0,
              sampleCount <= 960,
              pcmData.count == Int(sampleCount) * MemoryLayout<Int16>.size else {
            Self.logger.error(
                "PCM rejected by validation stream=\(streamID, privacy: .public) samples=\(sampleCount, privacy: .public) bytes=\(pcmData.count, privacy: .public)"
            )
            return false
        }
        guard let context = currentReadyContext() else {
            Self.logger.error("PCM rejected because RFB is not ready stream=\(streamID, privacy: .public)")
            return false
        }

        let reservation = reserveMicrophonePacket(
            transport: context.transport,
            connectionToken: context.token,
            streamID: streamID
        )
        switch reservation {
        case .rejected(let reason):
            Self.logger.error(
                "PCM reservation rejected stream=\(streamID, privacy: .public) reason=\(reason, privacy: .public)"
            )
            return false
        case .overflow(let pendingPackets):
            Self.logger.error(
                "PCM queue overflow stream=\(streamID, privacy: .public) pending=\(pendingPackets, privacy: .public)"
            )
            // Drop every queued PCM packet for this stream and put STOP behind
            // any message already being written. The coordinator also observes
            // the false return and releases its logical ownership immediately.
            endMicrophoneStream(
                streamID: streamID,
                timestampMicroseconds: DispatchTime.now().uptimeNanoseconds / 1_000
            )
            return false
        case .accepted(let sendGeneration):
            ioQueue.async { [weak self, transport = context.transport] in
                guard let self else { return }
                defer { self.finishMicrophonePacket(generation: sendGeneration) }
                guard self.isCurrentReady(transport: transport, token: context.token),
                      self.isMicrophoneSendStateCurrent(
                          transport: transport,
                          connectionToken: context.token,
                          streamID: streamID,
                          generation: sendGeneration,
                          requireAccepting: true
                      ),
                      transport.activeMicrophoneStreamID == streamID else {
                    Self.logger.error(
                        "Queued PCM dropped because RFB stream state changed stream=\(streamID, privacy: .public)"
                    )
                    return
                }
                do {
                    try self.writeMicrophoneMessage(
                        Self.microphoneMessage(
                            flags: 0x04,
                            streamID: streamID,
                            packetSequence: packetSequence,
                            timestampMicroseconds: timestampMicroseconds,
                            sampleCount: sampleCount,
                            pcmData: pcmData
                        ),
                        to: transport
                    )
                } catch let error as ClientError {
                    Self.logger.error(
                        "PCM write failed stream=\(streamID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    self.invalidateMicrophoneSendState(
                        transport: transport,
                        connectionToken: context.token,
                        streamID: streamID
                    )
                    self.failActiveConnection(transport: transport, token: context.token, error: error)
                } catch {
                    Self.logger.error(
                        "PCM write failed stream=\(streamID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    self.invalidateMicrophoneSendState(
                        transport: transport,
                        connectionToken: context.token,
                        streamID: streamID
                    )
                    self.failActiveConnection(transport: transport, token: context.token, error: .inputWriteFailed)
                }
            }
            return true
        }
    }

    func endMicrophoneStream(streamID: UInt32, timestampMicroseconds: UInt64) {
        guard streamID != 0, let context = currentReadyContext() else { return }
        invalidateMicrophoneSendState(
            transport: context.transport,
            connectionToken: context.token,
            streamID: streamID
        )
        ioQueue.async { [weak self, transport = context.transport] in
            guard let self,
                  self.isCurrentReady(transport: transport, token: context.token),
                  transport.activeMicrophoneStreamID == streamID else { return }
            defer { transport.activeMicrophoneStreamID = nil }
            do {
                try self.writeMessage(
                    Self.microphoneMessage(
                        flags: 0x02,
                        streamID: streamID,
                        packetSequence: 0,
                        timestampMicroseconds: timestampMicroseconds,
                        sampleCount: 0,
                        pcmData: Data()
                    ),
                    to: transport
                )
            } catch let error as ClientError {
                self.failActiveConnection(transport: transport, token: context.token, error: error)
            } catch {
                self.failActiveConnection(transport: transport, token: context.token, error: .inputWriteFailed)
            }
        }
    }

    private func beginMicrophoneSendState(
        transport: RFBTransport,
        connectionToken: UInt64,
        streamID: UInt32
    ) -> UInt64? {
        microphoneSendLock.lock()
        defer { microphoneSendLock.unlock() }
        guard microphoneOutboundState == nil else { return nil }
        microphoneSendGeneration &+= 1
        let sendGeneration = microphoneSendGeneration
        microphoneOutboundState = MicrophoneOutboundState(
            transport: transport,
            connectionToken: connectionToken,
            streamID: streamID,
            generation: sendGeneration,
            acceptingPackets: true,
            pendingPackets: 0
        )
        return sendGeneration
    }

    private func reserveMicrophonePacket(
        transport: RFBTransport,
        connectionToken: UInt64,
        streamID: UInt32
    ) -> MicrophonePacketReservation {
        microphoneSendLock.lock()
        defer { microphoneSendLock.unlock() }
        guard var state = microphoneOutboundState else {
            return .rejected(reason: "missing-state")
        }
        guard state.transport === transport else {
            return .rejected(reason: "transport-mismatch")
        }
        guard state.connectionToken == connectionToken else {
            return .rejected(reason: "connection-token-mismatch")
        }
        guard state.streamID == streamID else {
            return .rejected(reason: "stream-id-mismatch")
        }
        guard state.acceptingPackets else {
            return .rejected(reason: "not-accepting")
        }
        guard state.pendingPackets < Self.maximumPendingMicrophonePackets else {
            state.acceptingPackets = false
            microphoneOutboundState = state
            return .overflow(pendingPackets: state.pendingPackets)
        }
        state.pendingPackets += 1
        microphoneOutboundState = state
        return .accepted(generation: state.generation)
    }

    private func finishMicrophonePacket(generation expectedGeneration: UInt64) {
        microphoneSendLock.lock()
        defer { microphoneSendLock.unlock() }
        guard var state = microphoneOutboundState,
              state.generation == expectedGeneration else { return }
        state.pendingPackets = max(0, state.pendingPackets - 1)
        microphoneOutboundState = state
    }

    private func isMicrophoneSendStateCurrent(
        transport: RFBTransport,
        connectionToken: UInt64,
        streamID: UInt32,
        generation expectedGeneration: UInt64,
        requireAccepting: Bool
    ) -> Bool {
        microphoneSendLock.lock()
        defer { microphoneSendLock.unlock() }
        guard let state = microphoneOutboundState,
              state.transport === transport,
              state.connectionToken == connectionToken,
              state.streamID == streamID,
              state.generation == expectedGeneration else { return false }
        return !requireAccepting || state.acceptingPackets
    }

    private func invalidateMicrophoneSendState(
        transport: RFBTransport,
        connectionToken: UInt64,
        streamID: UInt32
    ) {
        microphoneSendLock.lock()
        if let state = microphoneOutboundState,
           state.transport === transport,
           state.connectionToken == connectionToken,
           state.streamID == streamID {
            microphoneSendGeneration &+= 1
            microphoneOutboundState = nil
        }
        microphoneSendLock.unlock()
    }

    private func invalidateAllMicrophoneSends() {
        microphoneSendLock.lock()
        microphoneSendGeneration &+= 1
        microphoneOutboundState = nil
        microphoneSendLock.unlock()
    }

    // MARK: - Connection lifecycle

    private func performConnect(
        password: String,
        token: UInt64,
        completion: @escaping ConnectCompletion
    ) {
        guard isCurrentGeneration(token) else {
            complete(completion, with: .failure(ClientError.cancelled))
            return
        }

        var socketFD: Int32 = -1
        let bridgeStatus = targetUDID.withCString { pointer in
            IUSCUSBMuxConnectDevice(pointer, Self.trollVNCPort, &socketFD)
        }
        guard bridgeStatus == IUSCUSBMuxSuccess, socketFD >= 0 else {
            let error = Self.clientError(forBridgeStatus: bridgeStatus)
            failConnectionAttemptWithoutTransport(token: token, error: error)
            complete(completion, with: .failure(error))
            return
        }

        let transport = RFBTransport(fileDescriptor: socketFD)
        guard install(transport: transport, token: token) else {
            transport.requestCancellation()
            transport.close()
            complete(completion, with: .failure(ClientError.cancelled))
            return
        }

        var passwordBytes = Array(password.utf8)
        defer { Self.secureZero(&passwordBytes) }

        do {
            let serverInfo = try performHandshake(
                transport: transport,
                passwordBytes: passwordBytes
            )
            guard markReady(transport: transport, token: token, serverInfo: serverInfo) else {
                transport.requestCancellation()
                transport.close()
                complete(completion, with: .failure(ClientError.cancelled))
                return
            }

            monitorQueue.async { [weak self, transport] in
                guard let self else {
                    transport.requestCancellation()
                    transport.close()
                    return
                }
                self.monitorServerMessages(transport: transport, token: token)
            }

            notifyState(.connected(serverInfo), token: token)
            complete(completion, with: .success(serverInfo))
        } catch let error as ClientError {
            let reportedError: ClientError
            if transport.isCancellationRequested || !isCurrentGeneration(token) {
                reportedError = .cancelled
            } else {
                reportedError = error
            }
            finishFailedHandshake(transport: transport, token: token, error: reportedError)
            complete(completion, with: .failure(reportedError))
        } catch {
            let reportedError: ClientError = transport.isCancellationRequested ? .cancelled : .malformedServerData
            finishFailedHandshake(transport: transport, token: token, error: reportedError)
            complete(completion, with: .failure(reportedError))
        }
    }

    private func install(transport: RFBTransport, token: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard generation == token, activeTransport == nil else { return false }
        activeTransport = transport
        transportIsReady = false
        return true
    }

    private func markReady(
        transport: RFBTransport,
        token: UInt64,
        serverInfo: ServerInfo
    ) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard generation == token,
              activeTransport === transport,
              !transport.isCancellationRequested else {
            return false
        }
        transportIsReady = true
        storedState = .connected(serverInfo)
        return true
    }

    private func failConnectionAttemptWithoutTransport(token: UInt64, error: ClientError) {
        lifecycleLock.lock()
        guard generation == token, activeTransport == nil else {
            lifecycleLock.unlock()
            return
        }
        transportIsReady = false
        storedState = .disconnected
        lifecycleLock.unlock()

        notifyState(.disconnected, token: token)
        notifyError(error, token: token)
    }

    private func finishFailedHandshake(
        transport: RFBTransport,
        token: UInt64,
        error: ClientError
    ) {
        transport.requestCancellation()
        transport.close()

        lifecycleLock.lock()
        let wasCurrent = generation == token && activeTransport === transport
        if wasCurrent {
            activeTransport = nil
            transportIsReady = false
            storedState = .disconnected
        }
        lifecycleLock.unlock()

        guard wasCurrent, error != .cancelled else { return }
        notifyState(.disconnected, token: token)
        notifyError(error, token: token)
    }

    private func failActiveConnection(
        transport: RFBTransport,
        token: UInt64,
        error: ClientError
    ) {
        lifecycleLock.lock()
        let wasCurrent = generation == token && activeTransport === transport
        if wasCurrent {
            activeTransport = nil
            transportIsReady = false
            storedState = .disconnected
        }
        lifecycleLock.unlock()

        if wasCurrent {
            invalidateAllMicrophoneSends()
        }
        transport.requestCancellation()
        guard wasCurrent else { return }
        notifyState(.disconnected, token: token)
        notifyError(error, token: token)
    }

    private func currentReadyContext() -> (transport: RFBTransport, token: UInt64)? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard transportIsReady, let transport = activeTransport else { return nil }
        return (transport, generation)
    }

    private func isCurrentReady(transport: RFBTransport, token: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return generation == token && transportIsReady && activeTransport === transport
    }

    private func isCurrentGeneration(_ token: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return generation == token
    }

    private func notifyState(_ state: State, token: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentGeneration(token) else { return }
            self.lifecycleLock.lock()
            let callback = self.stateCallback
            self.lifecycleLock.unlock()
            callback?(state)
        }
    }

    private func notifyError(_ error: ClientError, token: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentGeneration(token) else { return }
            self.lifecycleLock.lock()
            let callback = self.errorCallback
            self.lifecycleLock.unlock()
            callback?(error)
        }
    }

    private func complete(_ completion: @escaping ConnectCompletion, with result: Result<ServerInfo, Error>) {
        DispatchQueue.main.async {
            completion(result)
        }
    }

    // MARK: - RFB handshake

    private func performHandshake(
        transport: RFBTransport,
        passwordBytes: [UInt8]
    ) throws -> ServerInfo {
        let deadline = Self.deadline(after: Self.handshakeTimeoutNanoseconds)
        let serverBanner = try readExactly(12, from: transport, deadline: deadline)
        let version = try Self.negotiatedVersion(from: serverBanner)
        try writeExactly(version.banner, to: transport, deadline: deadline)

        switch version {
        case .v3_3:
            let securityType = try readUInt32(from: transport, deadline: deadline)
            if securityType == 0 {
                try discardFailureReason(from: transport, deadline: deadline)
                throw ClientError.classicVNCAuthenticationUnavailable
            }
            guard securityType == 2 else {
                throw ClientError.classicVNCAuthenticationUnavailable
            }
        case .v3_7, .v3_8:
            let count = try readExactly(1, from: transport, deadline: deadline)[0]
            if count == 0 {
                try discardFailureReason(from: transport, deadline: deadline)
                throw ClientError.classicVNCAuthenticationUnavailable
            }
            let securityTypes = try readExactly(Int(count), from: transport, deadline: deadline)
            guard securityTypes.contains(2) else {
                throw ClientError.classicVNCAuthenticationUnavailable
            }
            try writeExactly([2], to: transport, deadline: deadline)
        }

        var challenge = try readExactly(16, from: transport, deadline: deadline)
        var response = [UInt8](repeating: 0, count: 16)
        defer {
            Self.secureZero(&challenge)
            Self.secureZero(&response)
        }

        let cryptoStatus = challenge.withUnsafeBytes { challengeBuffer in
            passwordBytes.withUnsafeBytes { passwordBuffer in
                response.withUnsafeMutableBytes { responseBuffer in
                    IUSCEncryptVNCChallenge(
                        challengeBuffer.bindMemory(to: UInt8.self).baseAddress,
                        passwordBuffer.bindMemory(to: UInt8.self).baseAddress,
                        passwordBuffer.count,
                        responseBuffer.bindMemory(to: UInt8.self).baseAddress
                    )
                }
            }
        }
        guard cryptoStatus == IUSCUSBMuxSuccess else {
            throw ClientError.authenticationFailed
        }
        try writeExactly(response, to: transport, deadline: deadline)

        let securityResult = try readUInt32(from: transport, deadline: deadline)
        guard securityResult == 0 else {
            if version == .v3_8 {
                try discardFailureReason(from: transport, deadline: deadline)
            }
            throw ClientError.authenticationFailed
        }

        // Shared-flag 1 avoids evicting another deliberate local viewer.
        try writeExactly([1], to: transport, deadline: deadline)

        let width = try readUInt16(from: transport, deadline: deadline)
        let height = try readUInt16(from: transport, deadline: deadline)
        guard width > 0, height > 0 else {
            throw ClientError.malformedServerData
        }

        // PixelFormat is needed to consume ServerInit but is intentionally not
        // applied: this client never asks the server to encode a framebuffer.
        _ = try readExactly(16, from: transport, deadline: deadline)
        let nameLength = try readUInt32(from: transport, deadline: deadline)
        guard nameLength <= Self.maximumServerNameLength else {
            throw ClientError.malformedServerData
        }
        try discardExactly(Int(nameLength), from: transport, deadline: deadline)

        return ServerInfo(
            protocolVersion: version,
            framebufferWidth: width,
            framebufferHeight: height
        )
    }

    private func discardFailureReason(
        from transport: RFBTransport,
        deadline: UInt64
    ) throws {
        let length = try readUInt32(from: transport, deadline: deadline)
        guard length <= Self.maximumFailureReasonLength else {
            throw ClientError.malformedServerData
        }
        try discardExactly(Int(length), from: transport, deadline: deadline)
    }

    private static func negotiatedVersion(from banner: [UInt8]) throws -> ProtocolVersion {
        guard banner.count == 12,
              banner[0] == 0x52, banner[1] == 0x46, banner[2] == 0x42, banner[3] == 0x20,
              banner[7] == 0x2E, banner[11] == 0x0A,
              banner[4...6].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              banner[8...10].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            throw ClientError.unsupportedProtocol
        }

        let major = Int(banner[4] - 0x30) * 100
            + Int(banner[5] - 0x30) * 10
            + Int(banner[6] - 0x30)
        let minor = Int(banner[8] - 0x30) * 100
            + Int(banner[9] - 0x30) * 10
            + Int(banner[10] - 0x30)
        guard major == 3, minor >= 3 else {
            throw ClientError.unsupportedProtocol
        }
        if minor >= 8 { return .v3_8 }
        if minor >= 7 { return .v3_7 }
        return .v3_3
    }

    // MARK: - Post-handshake server monitor

    private func monitorServerMessages(transport: RFBTransport, token: UInt64) {
        // Descriptor release is serialized behind all queued writers. The read
        // monitor has already returned at that point, so close cannot race a
        // poll/read/write and the descriptor cannot be reused underneath one.
        defer {
            ioQueue.async { [transport] in
                transport.close()
            }
        }

        do {
            while !transport.isCancellationRequested {
                guard try waitForReadableMessage(on: transport) else { continue }
                let deadline = Self.deadline(after: Self.serverPayloadTimeoutNanoseconds)
                let messageType = try readExactly(1, from: transport, deadline: deadline)[0]

                switch messageType {
                case 0:
                    // FramebufferUpdate is forbidden on this input-only channel.
                    throw ClientError.unexpectedServerMessage
                case 1:
                    // SetColourMapEntries: padding, first colour, count, RGB data.
                    let header = try readExactly(5, from: transport, deadline: deadline)
                    let colourCount = Int(Self.uint16(from: header, offset: 3))
                    try discardExactly(colourCount * 6, from: transport, deadline: deadline)
                case 2:
                    // Bell has no payload.
                    break
                case 3:
                    // ServerCutText is consumed and discarded; clipboard data is
                    // neither exposed nor logged by the input-only client.
                    let header = try readExactly(7, from: transport, deadline: deadline)
                    let length = Self.uint32(from: header, offset: 3)
                    guard length <= Self.maximumServerTextLength else {
                        throw ClientError.malformedServerData
                    }
                    try discardExactly(Int(length), from: transport, deadline: deadline)
                default:
                    throw ClientError.unexpectedServerMessage
                }
            }
        } catch let error as ClientError {
            if !transport.isCancellationRequested {
                let reportedError: ClientError = error == .handshakeTimedOut
                    ? .peerDisconnected
                    : error
                failActiveConnection(transport: transport, token: token, error: reportedError)
            }
        } catch {
            if !transport.isCancellationRequested {
                failActiveConnection(transport: transport, token: token, error: .peerDisconnected)
            }
        }
    }

    private func waitForReadableMessage(on transport: RFBTransport) throws -> Bool {
        guard !transport.isCancellationRequested else { throw ClientError.cancelled }

        var descriptor = pollfd(
            fd: transport.fileDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        let result = Darwin.poll(&descriptor, 1, 250)
        if result == 0 { return false }
        if result < 0 {
            if errno == EINTR { return false }
            throw transport.isCancellationRequested
                ? ClientError.cancelled
                : ClientError.peerDisconnected
        }
        if descriptor.revents & Int16(POLLIN) != 0 { return true }
        if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
            throw transport.isCancellationRequested
                ? ClientError.cancelled
                : ClientError.peerDisconnected
        }
        return false
    }

    // MARK: - Input messages

    private func releaseTrackedInputs(on transport: RFBTransport) throws {
        defer {
            transport.lastPointerMask = 0
            transport.pressedKeysyms.removeAll(keepingCapacity: false)
        }

        try writeMessage(
            Self.pointerMessage(
                mask: 0,
                x: transport.lastPointerX,
                y: transport.lastPointerY
            ),
            to: transport
        )
        for keysym in transport.pressedKeysyms.sorted() {
            try writeMessage(Self.keyMessage(down: false, keysym: keysym), to: transport)
        }
        if let streamID = transport.activeMicrophoneStreamID {
            try writeMessage(
                Self.microphoneMessage(
                    flags: 0x02,
                    streamID: streamID,
                    packetSequence: 0,
                    timestampMicroseconds: DispatchTime.now().uptimeNanoseconds / 1_000,
                    sampleCount: 0,
                    pcmData: Data()
                ),
                to: transport
            )
            transport.activeMicrophoneStreamID = nil
        }
    }

    private func writeMessage(_ message: [UInt8], to transport: RFBTransport) throws {
        do {
            try writeExactly(
                message,
                to: transport,
                deadline: Self.deadline(after: Self.messageTimeoutNanoseconds)
            )
        } catch ClientError.cancelled {
            throw ClientError.cancelled
        } catch {
            throw ClientError.inputWriteFailed
        }
    }

    /// PCM is lossy real-time traffic, so it may wait only a few milliseconds
    /// for the nonblocking usbmux socket. If a partial frame cannot finish by
    /// then, the connection is failed rather than leaving a corrupt RFB byte
    /// stream or blocking pointer/key events for the normal three-second limit.
    private func writeMicrophoneMessage(_ message: [UInt8], to transport: RFBTransport) throws {
        do {
            try writeExactly(
                message,
                to: transport,
                deadline: Self.deadline(after: Self.microphoneMessageTimeoutNanoseconds)
            )
        } catch ClientError.cancelled {
            throw ClientError.cancelled
        } catch {
            throw ClientError.inputWriteFailed
        }
    }

    private static func pointerMessage(mask: UInt8, x: UInt16, y: UInt16) -> [UInt8] {
        [
            5,
            mask,
            UInt8(truncatingIfNeeded: x >> 8),
            UInt8(truncatingIfNeeded: x),
            UInt8(truncatingIfNeeded: y >> 8),
            UInt8(truncatingIfNeeded: y)
        ]
    }

    private static func keyMessage(down: Bool, keysym: UInt32) -> [UInt8] {
        [
            4,
            down ? 1 : 0,
            0,
            0,
            UInt8(truncatingIfNeeded: keysym >> 24),
            UInt8(truncatingIfNeeded: keysym >> 16),
            UInt8(truncatingIfNeeded: keysym >> 8),
            UInt8(truncatingIfNeeded: keysym)
        ]
    }

    private static func microphoneMessage(
        flags: UInt8,
        streamID: UInt32,
        packetSequence: UInt32,
        timestampMicroseconds: UInt64,
        sampleCount: UInt16,
        pcmData: Data
    ) -> [UInt8] {
        var payload = [UInt8]()
        payload.reserveCapacity(28 + pcmData.count)
        payload.append(contentsOf: [0x49, 0x55, 0x4D, 0x43]) // IUMC
        payload.append(1)
        payload.append(flags)
        payload.append(contentsOf: bigEndianBytes(UInt16(28)))
        payload.append(contentsOf: bigEndianBytes(streamID))
        payload.append(contentsOf: bigEndianBytes(packetSequence))
        payload.append(contentsOf: bigEndianBytes(timestampMicroseconds))
        payload.append(contentsOf: bigEndianBytes(sampleCount))
        payload.append(1) // mono
        payload.append(1) // signed 16-bit little-endian PCM
        payload.append(contentsOf: pcmData)

        var message = [UInt8](repeating: 0, count: 8)
        message[0] = 6 // standard RFB ClientCutText
        let length = UInt32(payload.count)
        message[4] = UInt8(truncatingIfNeeded: length >> 24)
        message[5] = UInt8(truncatingIfNeeded: length >> 16)
        message[6] = UInt8(truncatingIfNeeded: length >> 8)
        message[7] = UInt8(truncatingIfNeeded: length)
        message.append(contentsOf: payload)
        return message
    }

    private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        let bigEndian = value.bigEndian
        return withUnsafeBytes(of: bigEndian) { Array($0) }
    }

    // MARK: - Socket I/O

    private func readExactly(
        _ count: Int,
        from transport: RFBTransport,
        deadline: UInt64
    ) throws -> [UInt8] {
        guard count >= 0 else { throw ClientError.malformedServerData }
        if count == 0 { return [] }

        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            if transport.isCancellationRequested { throw ClientError.cancelled }
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(
                    transport.fileDescriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
            }
            if bytesRead > 0 {
                offset += bytesRead
                continue
            }
            if bytesRead == 0 { throw ClientError.peerDisconnected }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                try waitForSocket(
                    transport: transport,
                    events: Int16(POLLIN),
                    deadline: deadline
                )
                continue
            }
            throw transport.isCancellationRequested
                ? ClientError.cancelled
                : ClientError.peerDisconnected
        }
        return buffer
    }

    private func discardExactly(
        _ count: Int,
        from transport: RFBTransport,
        deadline: UInt64
    ) throws {
        guard count >= 0 else { throw ClientError.malformedServerData }
        var remaining = count
        while remaining > 0 {
            let chunkSize = min(remaining, 16_384)
            _ = try readExactly(chunkSize, from: transport, deadline: deadline)
            remaining -= chunkSize
        }
    }

    private func writeExactly(
        _ bytes: [UInt8],
        to transport: RFBTransport,
        deadline: UInt64
    ) throws {
        var offset = 0
        while offset < bytes.count {
            if transport.isCancellationRequested { throw ClientError.cancelled }
            let bytesWritten = bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(
                    transport.fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if bytesWritten > 0 {
                offset += bytesWritten
                continue
            }
            if bytesWritten == 0 { throw ClientError.peerDisconnected }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                try waitForSocket(
                    transport: transport,
                    events: Int16(POLLOUT),
                    deadline: deadline
                )
                continue
            }
            throw transport.isCancellationRequested
                ? ClientError.cancelled
                : ClientError.peerDisconnected
        }
    }

    private func waitForSocket(
        transport: RFBTransport,
        events: Int16,
        deadline: UInt64
    ) throws {
        while true {
            if transport.isCancellationRequested { throw ClientError.cancelled }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw ClientError.handshakeTimedOut }

            let remaining = deadline - now
            let roundedMilliseconds = (remaining + 999_999) / 1_000_000
            let timeout = Int32(max(1, min(250, roundedMilliseconds)))
            var descriptor = pollfd(
                fd: transport.fileDescriptor,
                events: events,
                revents: 0
            )
            let result = Darwin.poll(&descriptor, 1, timeout)
            if result == 0 { continue }
            if result < 0 {
                if errno == EINTR { continue }
                throw transport.isCancellationRequested
                    ? ClientError.cancelled
                    : ClientError.peerDisconnected
            }
            if descriptor.revents & events != 0 { return }
            if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw transport.isCancellationRequested
                    ? ClientError.cancelled
                    : ClientError.peerDisconnected
            }
        }
    }

    private func readUInt16(from transport: RFBTransport, deadline: UInt64) throws -> UInt16 {
        let bytes = try readExactly(2, from: transport, deadline: deadline)
        return Self.uint16(from: bytes, offset: 0)
    }

    private func readUInt32(from transport: RFBTransport, deadline: UInt64) throws -> UInt32 {
        let bytes = try readExactly(4, from: transport, deadline: deadline)
        return Self.uint32(from: bytes, offset: 0)
    }

    private static func uint16(from bytes: [UInt8], offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func uint32(from bytes: [UInt8], offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func deadline(after nanoseconds: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(nanoseconds)
        return overflow ? UInt64.max : deadline
    }

    private static func secureZero(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            IUSCSecureZeroBuffer(buffer.baseAddress, buffer.count)
        }
        bytes.removeAll(keepingCapacity: false)
    }

    private static func clientError(forBridgeStatus status: Int32) -> ClientError {
        switch status {
        case Int32(IUSCUSBMuxNoUSBDevice):
            return .noUSBDevice
        case Int32(IUSCUSBMuxTargetNotConnected):
            return .targetUSBDeviceNotConnected
        case Int32(IUSCUSBMuxDaemonUnavailable):
            return .usbMuxUnavailable
        default:
            return .usbConnectionFailed
        }
    }
}

/// Owns one usbmuxd descriptor. Cancellation only calls shutdown; the handshake
/// owner or the writer queue closes it after the monitor has exited, preventing
/// descriptor reuse while another queue may still be returning from I/O.
private final class RFBTransport: @unchecked Sendable {
    let fileDescriptor: Int32

    var pressedKeysyms: Set<UInt32> = []
    var lastPointerX: UInt16 = 0
    var lastPointerY: UInt16 = 0
    var lastPointerMask: UInt8 = 0
    var activeMicrophoneStreamID: UInt32?

    private let stateLock = NSLock()
    private var cancellationRequested = false
    private var closed = false

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    var isCancellationRequested: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancellationRequested || closed
    }

    func requestCancellation() {
        stateLock.lock()
        guard !cancellationRequested, !closed else {
            stateLock.unlock()
            return
        }
        cancellationRequested = true
        stateLock.unlock()
        _ = IUSCUSBMuxShutdown(fileDescriptor)
    }

    func close() {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        cancellationRequested = true
        stateLock.unlock()

        _ = IUSCUSBMuxShutdown(fileDescriptor)
        _ = IUSCUSBMuxDisconnect(fileDescriptor)
    }
}
