import CoreFoundation
import Foundation
import NIOCore
import NIOWebSocket

private enum WebSocketProtocolFailure: Error {
    case invalidMessage
    case messageTooLarge
}

private struct WebSocketMessageAssembler {
    private enum Kind {
        case text
        case binary
    }

    private var kind: Kind?
    private var bytes = Data()

    mutating func consume(
        _ frame: WebSocketFrame,
        maximumBytes: Int
    ) throws -> (isText: Bool, data: Data)? {
        let frameKind: Kind
        switch frame.opcode {
        case .text: frameKind = .text
        case .binary: frameKind = .binary
        case .continuation:
            guard let kind else { throw WebSocketProtocolFailure.invalidMessage }
            frameKind = kind
        default:
            throw WebSocketProtocolFailure.invalidMessage
        }

        if frame.opcode != .continuation {
            guard kind == nil else { throw WebSocketProtocolFailure.invalidMessage }
            kind = frameKind
            bytes.removeAll(keepingCapacity: true)
        }

        var payload = frame.unmaskedData
        guard bytes.count + payload.readableBytes <= maximumBytes,
              let fragment = payload.readBytes(length: payload.readableBytes) else {
            reset()
            throw WebSocketProtocolFailure.messageTooLarge
        }
        bytes.append(contentsOf: fragment)

        guard frame.fin else { return nil }
        let message = (isText: kind == .text, data: bytes)
        reset()
        return message
    }

    mutating func reset() {
        kind = nil
        bytes.removeAll(keepingCapacity: true)
    }
}

private enum WebSocketWire {
    static func sendJSON(
        _ object: Any,
        context: ChannelHandlerContext,
        promise: EventLoopPromise<Void>? = nil
    ) {
        guard let data = WebConsoleJSON.data(object) else { return }
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.writeAndFlush(
            NIOAny(WebSocketFrame(fin: true, opcode: .text, data: buffer)),
            promise: promise
        )
    }

    static func sendPong(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        context.writeAndFlush(
            NIOAny(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)),
            promise: nil
        )
    }

    static func close(
        context: ChannelHandlerContext,
        code: UInt16,
        reason: String
    ) {
        var payload = context.channel.allocator.buffer(capacity: 2 + min(123, reason.utf8.count))
        payload.writeInteger(code, endianness: .big)
        payload.writeString(String(reason.prefix(123)))
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [weak channel = context.channel] _ in
            channel?.close(promise: nil)
        }
        context.writeAndFlush(
            NIOAny(WebSocketFrame(fin: true, opcode: .connectionClose, data: payload)),
            promise: promise
        )
    }
}

final class WebRejectedSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame

    private let code: String
    private let message: String
    private let closeCode: UInt16

    init(code: String, message: String, closeCode: UInt16) {
        self.code = code
        self.message = message
        self.closeCode = closeCode
    }

    func handlerAdded(context: ChannelHandlerContext) {
        WebSocketWire.sendJSON(
            [
                "v": 1,
                "type": "error",
                "code": code,
                "message": message,
                "recoverable": false
            ],
            context: context
        )
        WebSocketWire.close(context: context, code: closeCode, reason: code)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
}

final class WebVideoSocketHandler: ChannelInboundHandler, WebVideoSink {
    typealias InboundIn = WebSocketFrame

    private static let maximumInboundMessageBytes = 1_024

    private let sessionToken: String
    private let auth: WebAuthStore
    private let hub: WebVideoHub

    private var context: ChannelHandlerContext?
    private var sessionTask: RepeatedTask?
    private var assembler = WebSocketMessageAssembler()
    private var invalidMessageCount = 0

    // Accessed only on the channel event loop.
    private var writeInFlight = false
    private var writeDeadline: Scheduled<Void>?
    private var writeGeneration: UInt64 = 0
    private var pendingAccessUnit: H264AccessUnit?
    private var requiresKeyFrame = true
    private var keyFrameRequested = false

    init(sessionToken: String, auth: WebAuthStore, hub: WebVideoHub) {
        self.sessionToken = sessionToken
        self.auth = auth
        self.hub = hub
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        guard hub.register(self) else {
            WebSocketWire.sendJSON(
                [
                    "v": 1,
                    "type": "error",
                    "code": "viewer_limit",
                    "message": "视频查看会话已达到上限。",
                    "recoverable": true
                ],
                context: context
            )
            WebSocketWire.close(context: context, code: 1008, reason: "viewer limit")
            return
        }
        sessionTask = context.eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(15),
            delay: .seconds(15)
        ) { [weak self] task in
            guard let self, let context = self.context else {
                task.cancel()
                return
            }
            guard self.auth.validate(token: self.sessionToken, touch: false) != nil else {
                task.cancel()
                WebSocketWire.close(context: context, code: 4401, reason: "session expired")
                return
            }
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        cleanUp()
    }

    func channelInactive(context: ChannelHandlerContext) {
        cleanUp()
        context.fireChannelInactive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        drainPendingIfPossible(context: context)
        context.fireChannelWritabilityChanged()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .ping:
            WebSocketWire.sendPong(frame, context: context)
        case .pong:
            break
        case .connectionClose:
            WebSocketWire.close(context: context, code: 1000, reason: "closing")
        case .text, .binary, .continuation:
            do {
                guard let message = try assembler.consume(
                    frame,
                    maximumBytes: Self.maximumInboundMessageBytes
                ) else { return }
                guard message.isText,
                      let object = WebConsoleJSON.object(message.data),
                      WebSocketValue.integer(object["v"]) == 1,
                      object["type"] as? String == "resync",
                      object["afterSequence"] == nil || WebSocketValue.uint32(object["afterSequence"]) != nil else {
                    recordInvalidMessage(context: context)
                    return
                }
                invalidMessageCount = 0
                requiresKeyFrame = true
                pendingAccessUnit = nil
                requestKeyFrameIfNeeded()
                hub.resendConfiguration(to: self)
            } catch WebSocketProtocolFailure.messageTooLarge {
                WebSocketWire.close(context: context, code: 1009, reason: "message too large")
            } catch {
                recordInvalidMessage(context: context)
            }
        default:
            recordInvalidMessage(context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func offer(configuration: H264StreamConfiguration) {
        guard let context else { return }
        context.eventLoop.execute { [weak self, weak context] in
            guard let self, let context, context.channel.isActive else { return }
            requiresKeyFrame = true
            pendingAccessUnit = nil
            keyFrameRequested = false
            WebSocketWire.sendJSON(
                [
                    "v": 1,
                    "type": "config",
                    "codec": configuration.codec,
                    "codedWidth": configuration.codedWidth,
                    "codedHeight": configuration.codedHeight,
                    "description": configuration.avcDecoderConfigurationRecord.base64EncodedString()
                ],
                context: context
            )
            requestKeyFrameIfNeeded()
        }
    }

    func offer(accessUnit: H264AccessUnit) {
        guard let context else { return }
        context.eventLoop.execute { [weak self, weak context] in
            guard let self, let context, context.channel.isActive else { return }

            if requiresKeyFrame {
                guard accessUnit.isKeyFrame else {
                    requestKeyFrameIfNeeded()
                    return
                }
                keyFrameRequested = false
            }

            guard !writeInFlight, context.channel.isWritable else {
                if pendingAccessUnit == nil {
                    pendingAccessUnit = accessUnit
                } else if pendingAccessUnit?.isKeyFrame != true {
                    // Replacing any delta frame breaks the prediction chain.
                    pendingAccessUnit = accessUnit.isKeyFrame ? accessUnit : nil
                    requiresKeyFrame = !accessUnit.isKeyFrame
                    requestKeyFrameIfNeeded()
                }
                return
            }
            send(accessUnit: accessUnit, context: context)
        }
    }

    func closeForServerShutdown() {
        guard let context else { return }
        context.eventLoop.execute { [weak context] in
            guard let context else { return }
            WebSocketWire.close(context: context, code: 1001, reason: "server stopping")
        }
    }

    private func send(accessUnit: H264AccessUnit, context: ChannelHandlerContext) {
        guard !requiresKeyFrame || accessUnit.isKeyFrame else {
            requestKeyFrameIfNeeded()
            return
        }
        if accessUnit.isKeyFrame {
            requiresKeyFrame = false
            keyFrameRequested = false
        }

        var buffer = context.channel.allocator.buffer(capacity: 20 + accessUnit.avccData.count)
        buffer.writeString("IUVC")
        buffer.writeInteger(UInt8(1))
        buffer.writeInteger(UInt8(accessUnit.isKeyFrame ? 1 : 0))
        buffer.writeInteger(UInt16(20), endianness: .big)
        buffer.writeInteger(accessUnit.timestampMicroseconds, endianness: .big)
        buffer.writeInteger(accessUnit.sequence, endianness: .big)
        buffer.writeBytes(accessUnit.avccData)

        writeInFlight = true
        writeGeneration &+= 1
        let generation = writeGeneration
        writeDeadline?.cancel()
        writeDeadline = context.eventLoop.scheduleTask(in: .seconds(5)) { [weak self, weak context] in
            guard let self, let context,
                  self.writeInFlight,
                  self.writeGeneration == generation else { return }
            self.writeDeadline = nil
            self.pendingAccessUnit = nil
            context.close(promise: nil)
        }
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [weak self, weak context] result in
            guard let self, let context else { return }
            guard self.writeGeneration == generation else { return }
            self.writeDeadline?.cancel()
            self.writeDeadline = nil
            writeInFlight = false
            if case .failure = result {
                context.close(promise: nil)
            } else {
                drainPendingIfPossible(context: context)
            }
        }
        context.writeAndFlush(
            NIOAny(WebSocketFrame(fin: true, opcode: .binary, data: buffer)),
            promise: promise
        )
    }

    private func drainPendingIfPossible(context: ChannelHandlerContext) {
        guard !writeInFlight, context.channel.isWritable, let pendingAccessUnit else { return }
        self.pendingAccessUnit = nil
        send(accessUnit: pendingAccessUnit, context: context)
    }

    private func requestKeyFrameIfNeeded() {
        guard !keyFrameRequested else { return }
        keyFrameRequested = true
        hub.requestKeyFrame?()
    }

    private func recordInvalidMessage(context: ChannelHandlerContext) {
        invalidMessageCount += 1
        if invalidMessageCount >= 3 {
            WebSocketWire.close(context: context, code: 1008, reason: "invalid protocol message")
        }
    }

    private func cleanUp() {
        sessionTask?.cancel()
        sessionTask = nil
        if context != nil {
            hub.unregister(self)
        }
        context = nil
        writeDeadline?.cancel()
        writeDeadline = nil
        writeGeneration &+= 1
        writeInFlight = false
        pendingAccessUnit = nil
    }
}

final class WebAudioSocketHandler: ChannelInboundHandler, WebAudioSink {
    typealias InboundIn = WebSocketFrame

    private static let maximumInboundMessageBytes = 1_024
    private static let maximumPendingPackets = 5
    private static let clientIdleTimeoutNanoseconds: UInt64 = 15_000_000_000

    private let sessionToken: String
    private let auth: WebAuthStore
    private let hub: WebAudioHub

    private let lifecycleLock = NSLock()
    private var context: ChannelHandlerContext?
    private var registeredWithHub = false
    private var sessionTask: RepeatedTask?
    private var lastInboundAtNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var assembler = WebSocketMessageAssembler()
    private var invalidMessageCount = 0
    private var writeInFlight = false
    private var writeDeadline: Scheduled<Void>?
    private var writeGeneration: UInt64 = 0
    private var pendingPackets: [OpusAudioPacket] = []
    private var forceDiscontinuityOnNextWrite = true

    init(sessionToken: String, auth: WebAuthStore, hub: WebAudioHub) {
        self.sessionToken = sessionToken
        self.auth = auth
        self.hub = hub
    }

    func handlerAdded(context: ChannelHandlerContext) {
        setContext(context)
        guard hub.register(self) else {
            WebSocketWire.sendJSON(
                [
                    "v": 1,
                    "type": "error",
                    "code": "viewer_limit",
                    "message": "音频查看会话已达到上限。",
                    "recoverable": true
                ],
                context: context
            )
            WebSocketWire.close(context: context, code: 1008, reason: "viewer limit")
            return
        }
        registeredWithHub = true
        lastInboundAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        sessionTask = context.eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(5),
            delay: .seconds(5)
        ) { [weak self] task in
            guard let self, self.isCurrent(context) else {
                task.cancel()
                return
            }
            guard self.auth.validate(token: self.sessionToken, touch: false) != nil else {
                task.cancel()
                WebSocketWire.close(context: context, code: 4401, reason: "session expired")
                return
            }
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now &- min(now, self.lastInboundAtNanoseconds)
            guard elapsed <= Self.clientIdleTimeoutNanoseconds else {
                task.cancel()
                WebSocketWire.close(context: context, code: 4000, reason: "audio heartbeat timeout")
                return
            }
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        cleanUp()
    }

    func channelInactive(context: ChannelHandlerContext) {
        cleanUp()
        context.fireChannelInactive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        drainPendingIfPossible(context: context)
        context.fireChannelWritabilityChanged()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        lastInboundAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .ping:
            WebSocketWire.sendPong(frame, context: context)
        case .pong:
            break
        case .connectionClose:
            WebSocketWire.close(context: context, code: 1000, reason: "closing")
        case .text, .binary, .continuation:
            do {
                guard let message = try assembler.consume(
                    frame,
                    maximumBytes: Self.maximumInboundMessageBytes
                ) else { return }
                guard message.isText,
                      let object = WebConsoleJSON.object(message.data),
                      WebSocketValue.integer(object["v"]) == 1,
                      let type = object["type"] as? String else {
                    recordInvalidMessage(context: context)
                    return
                }
                if type == "resync" {
                    pendingPackets.removeAll(keepingCapacity: true)
                    forceDiscontinuityOnNextWrite = true
                    hub.resendConfiguration(to: self)
                    invalidMessageCount = 0
                } else if type == "ping",
                          let identifier = object["id"] as? String,
                          identifier.count <= 128 {
                    WebSocketWire.sendJSON(
                        ["v": 1, "type": "pong", "id": identifier],
                        context: context
                    )
                    invalidMessageCount = 0
                } else {
                    recordInvalidMessage(context: context)
                }
            } catch WebSocketProtocolFailure.messageTooLarge {
                WebSocketWire.close(context: context, code: 1009, reason: "message too large")
            } catch {
                recordInvalidMessage(context: context)
            }
        default:
            recordInvalidMessage(context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func offer(configuration: OpusStreamConfiguration) {
        guard let context = contextSnapshot() else { return }
        context.eventLoop.execute { [weak self, weak context] in
            guard let self, let context, self.isCurrent(context), context.channel.isActive else { return }
            pendingPackets.removeAll(keepingCapacity: true)
            forceDiscontinuityOnNextWrite = true
            var message: [String: Any] = [
                "v": 1,
                "type": "config",
                "stream": configuration.codec == "pcm_s16le" ? "audio-pcm" : "audio",
                "codec": configuration.codec,
                "sampleRate": configuration.sampleRate,
                "numberOfChannels": configuration.numberOfChannels,
                "frameDurationUs": configuration.frameDurationMicroseconds
            ]
            if configuration.codec == "pcm_s16le" {
                message["sampleFormat"] = "s16le-interleaved"
            }
            WebSocketWire.sendJSON(
                message,
                context: context
            )
        }
    }

    func offer(packet: OpusAudioPacket) {
        guard let context = contextSnapshot() else { return }
        context.eventLoop.execute { [weak self, weak context] in
            guard let self, let context, self.isCurrent(context), context.channel.isActive else { return }
            guard !writeInFlight, context.channel.isWritable else {
                if pendingPackets.count >= Self.maximumPendingPackets {
                    pendingPackets.removeAll(keepingCapacity: true)
                    forceDiscontinuityOnNextWrite = true
                }
                pendingPackets.append(packet)
                return
            }
            send(packet: packet, context: context)
        }
    }

    func closeForServerShutdown() {
        guard let context = contextSnapshot() else { return }
        context.eventLoop.execute { [weak self, weak context] in
            guard let self, let context, self.isCurrent(context) else { return }
            WebSocketWire.close(context: context, code: 1001, reason: "server stopping")
        }
    }

    private func send(packet originalPacket: OpusAudioPacket, context: ChannelHandlerContext) {
        let packet = forceDiscontinuityOnNextWrite
            ? originalPacket.markingDiscontinuity()
            : originalPacket
        forceDiscontinuityOnNextWrite = false

        var buffer = context.channel.allocator.buffer(capacity: 24 + packet.payload.count)
        buffer.writeString("IUAC")
        buffer.writeInteger(UInt8(1))
        buffer.writeInteger(UInt8(packet.discontinuity ? 1 : 0))
        buffer.writeInteger(UInt16(24), endianness: .big)
        buffer.writeInteger(packet.timestampMicroseconds, endianness: .big)
        buffer.writeInteger(packet.sequence, endianness: .big)
        buffer.writeInteger(packet.frameCount, endianness: .big)
        buffer.writeInteger(UInt16(clamping: packet.payload.count), endianness: .big)
        buffer.writeBytes(packet.payload)

        writeInFlight = true
        writeGeneration &+= 1
        let generation = writeGeneration
        writeDeadline?.cancel()
        writeDeadline = context.eventLoop.scheduleTask(in: .seconds(5)) { [weak self, weak context] in
            guard let self, let context,
                  self.writeInFlight,
                  self.writeGeneration == generation else { return }
            self.writeDeadline = nil
            self.pendingPackets.removeAll(keepingCapacity: false)
            context.close(promise: nil)
        }
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [weak self, weak context] result in
            guard let self, let context, writeGeneration == generation else { return }
            writeDeadline?.cancel()
            writeDeadline = nil
            writeInFlight = false
            if case .failure = result {
                context.close(promise: nil)
            } else {
                drainPendingIfPossible(context: context)
            }
        }
        context.writeAndFlush(
            NIOAny(WebSocketFrame(fin: true, opcode: .binary, data: buffer)),
            promise: promise
        )
    }

    private func drainPendingIfPossible(context: ChannelHandlerContext) {
        guard !writeInFlight, context.channel.isWritable, !pendingPackets.isEmpty else { return }
        let packet = pendingPackets.removeFirst()
        send(packet: packet, context: context)
    }

    private func recordInvalidMessage(context: ChannelHandlerContext) {
        invalidMessageCount += 1
        if invalidMessageCount >= 3 {
            WebSocketWire.close(context: context, code: 1008, reason: "invalid protocol message")
        }
    }

    private func cleanUp() {
        sessionTask?.cancel()
        sessionTask = nil
        let wasCurrent = clearContext()
        if wasCurrent, registeredWithHub {
            hub.unregister(self)
        }
        registeredWithHub = false
        writeDeadline?.cancel()
        writeDeadline = nil
        writeGeneration &+= 1
        writeInFlight = false
        pendingPackets.removeAll(keepingCapacity: false)
    }

    private func setContext(_ context: ChannelHandlerContext) {
        lifecycleLock.lock()
        self.context = context
        lifecycleLock.unlock()
    }

    private func contextSnapshot() -> ChannelHandlerContext? {
        lifecycleLock.lock()
        let snapshot = context
        lifecycleLock.unlock()
        return snapshot
    }

    private func isCurrent(_ candidate: ChannelHandlerContext) -> Bool {
        lifecycleLock.lock()
        let current = context === candidate
        lifecycleLock.unlock()
        return current
    }

    @discardableResult
    private func clearContext() -> Bool {
        lifecycleLock.lock()
        let hadContext = context != nil
        context = nil
        lifecycleLock.unlock()
        return hadContext
    }
}

final class WebControlSocketHandler: ChannelInboundHandler, WebControlStateSink {
    typealias InboundIn = WebSocketFrame

    private static let maximumInboundMessageBytes = 4 * 1_024
    private static let clientIdleTimeoutNanoseconds: UInt64 = 12_000_000_000

    private let sessionToken: String
    private let leaseIdentifier: String
    private let auth: WebAuthStore
    private let status: WebConsoleStatusStore
    private let inputClient: RFBInputClient
    private let microphoneCoordinator: MicrophoneInputCoordinator
    private let controllers: WebControllerChannelRegistry

    private var context: ChannelHandlerContext?
    private var sessionTask: RepeatedTask?
    private var lastInboundAtNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var assembler = WebSocketMessageAssembler()
    private var invalidMessageCount = 0
    private var lastSequence: UInt32?
    private var activePointerMask: UInt8 = 0
    private var lastPointerPoint: (x: UInt16, y: UInt16)?
    private var pendingMove: (mask: UInt8, x: UInt16, y: UInt16)?
    private var moveTask: Scheduled<Void>?
    private var lastMoveSentAtNanoseconds: UInt64 = 0
    private var pressedKeysymsByCode: [String: UInt32] = [:]
    private var pointerTransitionRate = MessageRateWindow()
    private var keyRate = MessageRateWindow()
    private var commandRate = MessageRateWindow()
    private var microphonePacketRate = MessageRateWindow()
    private var activeMicrophoneStreamID: UInt32?
    private var lastMicrophoneSequence: UInt32?
    private var microphoneWatchdog: Scheduled<Void>?
    private var cleanedUp = false

    init(
        sessionToken: String,
        leaseIdentifier: String,
        auth: WebAuthStore,
        status: WebConsoleStatusStore,
        inputClient: RFBInputClient,
        microphoneCoordinator: MicrophoneInputCoordinator,
        controllers: WebControllerChannelRegistry
    ) {
        self.sessionToken = sessionToken
        self.leaseIdentifier = leaseIdentifier
        self.auth = auth
        self.status = status
        self.inputClient = inputClient
        self.microphoneCoordinator = microphoneCoordinator
        self.controllers = controllers
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        controllers.register(identifier: leaseIdentifier, channel: context.channel, stateSink: self)
        offer(status: status.snapshot())
        sendMicrophoneState("ready", context: context)
        lastInboundAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        sessionTask = context.eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(4),
            delay: .seconds(4)
        ) { [weak self] task in
            guard let self, let context = self.context else {
                task.cancel()
                return
            }
            guard self.auth.validate(token: self.sessionToken, touch: false) != nil else {
                task.cancel()
                self.releaseAllInputs()
                WebSocketWire.close(context: context, code: 4401, reason: "session expired")
                return
            }
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now &- min(now, self.lastInboundAtNanoseconds)
            guard elapsed <= Self.clientIdleTimeoutNanoseconds else {
                task.cancel()
                self.releaseAllInputs()
                WebSocketWire.close(context: context, code: 4000, reason: "control heartbeat timeout")
                return
            }
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        cleanUp()
    }

    func channelInactive(context: ChannelHandlerContext) {
        cleanUp()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        lastInboundAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .ping:
            WebSocketWire.sendPong(frame, context: context)
        case .pong:
            break
        case .connectionClose:
            WebSocketWire.close(context: context, code: 1000, reason: "closing")
        case .text, .binary, .continuation:
            do {
                guard let message = try assembler.consume(
                    frame,
                    maximumBytes: Self.maximumInboundMessageBytes
                ) else { return }
                if message.isText {
                    guard let object = WebConsoleJSON.object(message.data) else {
                        recordInvalidMessage(context: context, code: "invalid_message", message: "控制消息格式无效。")
                        return
                    }
                    handle(object: object, context: context)
                } else {
                    handleMicrophoneBinary(message.data, context: context)
                }
            } catch WebSocketProtocolFailure.messageTooLarge {
                releaseAllInputs()
                WebSocketWire.close(context: context, code: 1009, reason: "message too large")
            } catch {
                recordInvalidMessage(context: context, code: "invalid_message", message: "控制消息格式无效。")
            }
        default:
            recordInvalidMessage(context: context, code: "invalid_message", message: "不支持的控制消息。")
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        cleanUp()
        context.close(promise: nil)
    }

    func offer(status: WebConsoleStatusSnapshot) {
        guard let context else { return }
        context.eventLoop.execute { [weak context] in
            guard let context, context.channel.isActive else { return }
            WebSocketWire.sendJSON(status.controlStateJSONObject, context: context)
        }
    }

    func closeForSessionExpiry() {
        guard let context else { return }
        context.eventLoop.execute { [weak self, weak context] in
            guard let self, let context, context.channel.isActive else { return }
            self.releaseAllInputs()
            WebSocketWire.close(context: context, code: 4401, reason: "session expired")
        }
    }

    private func handle(object: [String: Any], context: ChannelHandlerContext) {
        guard WebSocketValue.integer(object["v"]) == 1,
              let type = object["type"] as? String else {
            recordInvalidMessage(context: context, code: "invalid_message", message: "控制消息版本无效。")
            return
        }
        if type == "ping" {
            // A validated control heartbeat keeps the shared bridge session
            // alive. Without this touch, otherwise healthy video/audio/control
            // sockets are forcibly recycled at the 30-minute idle limit.
            guard validateSession(touch: true, context: context) else { return }
            handlePing(object: object, context: context)
            return
        }

        guard validateSession(touch: false, context: context) else { return }

        guard let sequence = WebSocketValue.uint32(object["seq"]), accept(sequence: sequence) else {
            recordInvalidMessage(context: context, code: "invalid_sequence", message: "控制消息顺序无效。")
            return
        }

        switch type {
        case "pointer": handlePointer(object: object, context: context)
        case "key": handleKey(object: object, context: context)
        case "command": handleCommand(object: object, context: context)
        default:
            recordInvalidMessage(context: context, code: "unknown_message", message: "未知的控制消息。")
        }
    }

    private func handleMicrophoneBinary(_ data: Data, context: ChannelHandlerContext) {
        guard data.count >= 28,
              data[0] == 0x49, data[1] == 0x55, data[2] == 0x4D, data[3] == 0x43,
              data[4] == 1,
              Self.uint16(data, at: 6) == 28,
              let streamID = Self.uint32(data, at: 8), streamID != 0,
              let packetSequence = Self.uint32(data, at: 12),
              let timestamp = Self.uint64(data, at: 16),
              let sampleCount = Self.uint16(data, at: 24),
              data[26] == 1,
              data[27] == 1 else {
            recordInvalidMessage(context: context, code: "invalid_microphone_packet", message: "麦克风数据格式无效。")
            return
        }
        guard validateSession(touch: true, context: context) else { return }

        let flags = data[5]
        switch flags {
        case 0x01:
            guard data.count == 28,
                  sampleCount == 0,
                  activeMicrophoneStreamID == nil else {
                recordInvalidMessage(context: context, code: "invalid_microphone_start", message: "麦克风开始状态无效。")
                return
            }
            switch microphoneCoordinator.begin(
                owner: "web:\(leaseIdentifier)",
                requestedStreamID: streamID
            ) {
            case .started:
                activeMicrophoneStreamID = streamID
                lastMicrophoneSequence = packetSequence
                invalidMessageCount = 0
                refreshMicrophoneWatchdog(context: context, streamID: streamID)
                sendMicrophoneState("active", streamID: streamID, context: context)
            case .busy:
                sendMicrophoneState(
                    "busy",
                    streamID: streamID,
                    message: "麦克风输入正在被另一控制端使用。",
                    context: context
                )
            case .controlUnavailable:
                sendMicrophoneState(
                    "unavailable",
                    streamID: streamID,
                    message: "USB 控制或手机音频桥当前不可用。",
                    context: context
                )
            }
        case 0x04:
            guard microphonePacketRate.allow(maximum: 60),
                  activeMicrophoneStreamID == streamID,
                  sampleCount == 960,
                  data.count == 28 + Int(sampleCount) * MemoryLayout<Int16>.size,
                  acceptMicrophoneSequence(packetSequence) else {
                recordInvalidMessage(context: context, code: "invalid_microphone_data", message: "麦克风数据顺序或速率无效。")
                return
            }
            let pcm = data.subdata(in: 28..<data.count)
            guard microphoneCoordinator.send(
                owner: "web:\(leaseIdentifier)",
                streamID: streamID,
                packetSequence: packetSequence,
                timestampMicroseconds: timestamp,
                sampleCount: sampleCount,
                pcmData: pcm
            ) else {
                releaseMicrophone(context: context, notify: false)
                sendMicrophoneState(
                    "unavailable",
                    streamID: streamID,
                    message: "手机麦克风输入流已中断。",
                    context: context
                )
                return
            }
            refreshMicrophoneWatchdog(context: context, streamID: streamID)
            invalidMessageCount = 0
        case 0x02:
            guard data.count == 28,
                  sampleCount == 0,
                  activeMicrophoneStreamID == streamID,
                  acceptMicrophoneSequence(packetSequence) else {
                recordInvalidMessage(context: context, code: "invalid_microphone_stop", message: "麦克风停止状态无效。")
                return
            }
            releaseMicrophone(context: context, notify: true)
            invalidMessageCount = 0
        default:
            recordInvalidMessage(context: context, code: "invalid_microphone_flags", message: "麦克风数据标志无效。")
        }
    }

    private func acceptMicrophoneSequence(_ sequence: UInt32) -> Bool {
        guard let last = lastMicrophoneSequence else {
            lastMicrophoneSequence = sequence
            return true
        }
        let distance = sequence &- last
        guard distance != 0, distance < 0x8000_0000 else { return false }
        lastMicrophoneSequence = sequence
        return true
    }

    private func releaseMicrophone(context: ChannelHandlerContext?, notify: Bool) {
        guard let streamID = activeMicrophoneStreamID else { return }
        microphoneWatchdog?.cancel()
        microphoneWatchdog = nil
        microphoneCoordinator.end(owner: "web:\(leaseIdentifier)", streamID: streamID)
        activeMicrophoneStreamID = nil
        lastMicrophoneSequence = nil
        if notify, let context, context.channel.isActive {
            sendMicrophoneState("ready", context: context)
        }
    }

    private func refreshMicrophoneWatchdog(context: ChannelHandlerContext, streamID: UInt32) {
        microphoneWatchdog?.cancel()
        microphoneWatchdog = context.eventLoop.scheduleTask(in: .milliseconds(1_500)) { [weak self, weak context] in
            guard let self, let context,
                  self.activeMicrophoneStreamID == streamID else { return }
            self.microphoneWatchdog = nil
            self.releaseMicrophone(context: context, notify: true)
        }
    }

    private func sendMicrophoneState(
        _ state: String,
        streamID: UInt32? = nil,
        message: String? = nil,
        context: ChannelHandlerContext
    ) {
        var object: [String: Any] = ["v": 1, "type": "microphoneState", "state": state]
        if let streamID { object["streamID"] = streamID }
        if let message { object["message"] = message }
        WebSocketWire.sendJSON(object, context: context)
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func uint64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }

    private func validateSession(touch: Bool, context: ChannelHandlerContext) -> Bool {
        guard auth.validate(token: sessionToken, touch: touch) != nil else {
            releaseAllInputs()
            WebSocketWire.sendJSON(
                errorObject(code: "unauthorized", message: "会话已失效。", recoverable: false),
                context: context
            )
            WebSocketWire.close(context: context, code: 4401, reason: "session expired")
            return false
        }
        return true
    }

    private func handlePing(object: [String: Any], context: ChannelHandlerContext) {
        guard let identifier = object["id"] as? String,
              identifier.count <= 128,
              let clientTime = WebSocketValue.finiteDouble(object["clientTimeMs"]) else {
            recordInvalidMessage(context: context, code: "invalid_ping", message: "心跳消息无效。")
            return
        }
        invalidMessageCount = 0
        WebSocketWire.sendJSON(
            [
                "v": 1,
                "type": "pong",
                "id": identifier,
                "clientTimeMs": clientTime,
                "serverTimeMs": Date().timeIntervalSince1970 * 1_000
            ],
            context: context
        )
    }

    private func handlePointer(object: [String: Any], context: ChannelHandlerContext) {
        guard let phase = object["phase"] as? String,
              let normalizedX = WebSocketValue.finiteDouble(object["x"]),
              let normalizedY = WebSocketValue.finiteDouble(object["y"]),
              (0...1).contains(normalizedX),
              (0...1).contains(normalizedY),
              let browserButtons = WebSocketValue.uint8(object["buttons"]),
              browserButtons & ~UInt8(0x07) == 0,
              let pointerType = object["pointerType"] as? String,
              ["touch", "mouse", "pen"].contains(pointerType) else {
            recordInvalidMessage(context: context, code: "invalid_pointer", message: "指针消息无效。")
            return
        }

        let snapshot = status.snapshot()
        guard snapshot.controlConnected,
              let width = snapshot.framebufferWidth,
              let height = snapshot.framebufferHeight else {
            sendRecoverableError(context: context, code: "control_unavailable", message: "USB 控制通道当前不可用。")
            return
        }
        let point = (
            x: Self.coordinate(normalizedX, extent: width),
            y: Self.coordinate(normalizedY, extent: height)
        )
        let mappedMask = Self.rfbMask(browserButtons: browserButtons)

        switch phase {
        case "down":
            guard pointerTransitionRate.allow(maximum: 40) else {
                recordInvalidMessage(context: context, code: "rate_limited", message: "指针事件过快。")
                return
            }
            guard activePointerMask == 0, mappedMask != 0 else {
                recordInvalidMessage(context: context, code: "invalid_pointer_transition", message: "指针按下状态无效。")
                return
            }
            guard validateSession(touch: true, context: context) else { return }
            activePointerMask = mappedMask
            lastPointerPoint = point
            cancelPendingMove()
            inputClient.sendPointer(mask: mappedMask, x: point.x, y: point.y)
        case "move":
            guard activePointerMask != 0, mappedMask == activePointerMask else {
                recordInvalidMessage(context: context, code: "invalid_pointer_transition", message: "指针移动状态无效。")
                return
            }
            guard validateSession(touch: true, context: context) else { return }
            lastPointerPoint = point
            enqueueMove(mask: activePointerMask, point: point, context: context)
        case "up":
            guard pointerTransitionRate.allow(maximum: 40) else {
                recordInvalidMessage(context: context, code: "rate_limited", message: "指针事件过快。")
                return
            }
            guard activePointerMask != 0, mappedMask == 0 else {
                recordInvalidMessage(context: context, code: "invalid_pointer_transition", message: "指针抬起状态无效。")
                return
            }
            guard validateSession(touch: true, context: context) else { return }
            cancelPendingMove()
            if lastPointerPoint?.x != point.x || lastPointerPoint?.y != point.y {
                inputClient.sendPointer(mask: activePointerMask, x: point.x, y: point.y)
            } else {
                // The latest coordinate may still have been coalesced. Always
                // send one final pressed point immediately before release.
                inputClient.sendPointer(mask: activePointerMask, x: point.x, y: point.y)
            }
            inputClient.sendPointer(mask: 0, x: point.x, y: point.y)
            activePointerMask = 0
            lastPointerPoint = point
        case "cancel":
            guard pointerTransitionRate.allow(maximum: 40) else {
                recordInvalidMessage(context: context, code: "rate_limited", message: "指针事件过快。")
                return
            }
            guard activePointerMask != 0, mappedMask == 0 else {
                recordInvalidMessage(context: context, code: "invalid_pointer_transition", message: "指针取消状态无效。")
                return
            }
            guard validateSession(touch: true, context: context) else { return }
            cancelPendingMove()
            inputClient.sendPointer(mask: 0, x: point.x, y: point.y)
            activePointerMask = 0
            lastPointerPoint = point
        default:
            recordInvalidMessage(context: context, code: "invalid_pointer", message: "未知的指针阶段。")
            return
        }
        invalidMessageCount = 0
    }

    private func handleKey(object: [String: Any], context: ChannelHandlerContext) {
        guard keyRate.allow(maximum: 120) else {
            recordInvalidMessage(context: context, code: "rate_limited", message: "键盘事件过快。")
            return
        }
        guard status.snapshot().controlConnected else {
            sendRecoverableError(context: context, code: "control_unavailable", message: "USB 控制通道当前不可用。")
            return
        }
        guard let phase = object["phase"] as? String,
              phase == "down" || phase == "up",
              let code = object["code"] as? String,
              !code.isEmpty, code.count <= 64,
              let key = object["key"] as? String,
              !key.isEmpty, key.utf8.count <= 16,
              object["modifiers"] is [String: Any],
              WebSocketValue.bool(object["repeat"]) != nil else {
            recordInvalidMessage(context: context, code: "invalid_key", message: "键盘消息无效。")
            return
        }

        if phase == "down" {
            let repeated = WebSocketValue.bool(object["repeat"]) == true
            if let existing = pressedKeysymsByCode[code] {
                guard repeated else {
                    recordInvalidMessage(context: context, code: "invalid_key_transition", message: "按键状态无效。")
                    return
                }
                guard validateSession(touch: true, context: context) else { return }
                inputClient.sendKey(down: true, keysym: existing)
            } else {
                guard let keysym = Self.keysym(code: code, key: key) else {
                    sendRecoverableError(context: context, code: "unsupported_key", message: "该按键暂不支持。")
                    return
                }
                guard validateSession(touch: true, context: context) else { return }
                pressedKeysymsByCode[code] = keysym
                inputClient.sendKey(down: true, keysym: keysym)
            }
        } else {
            guard let keysym = pressedKeysymsByCode[code] else {
                recordInvalidMessage(context: context, code: "invalid_key_transition", message: "按键释放状态无效。")
                return
            }
            guard validateSession(touch: true, context: context) else { return }
            pressedKeysymsByCode.removeValue(forKey: code)
            inputClient.sendKey(down: false, keysym: keysym)
        }
        invalidMessageCount = 0
    }

    private func handleCommand(object: [String: Any], context: ChannelHandlerContext) {
        guard commandRate.allow(maximum: 10) else {
            recordInvalidMessage(context: context, code: "rate_limited", message: "控制命令过快。")
            return
        }
        guard status.snapshot().controlConnected else {
            sendRecoverableError(context: context, code: "control_unavailable", message: "USB 控制通道当前不可用。")
            return
        }
        guard let name = object["name"] as? String,
              name == "home" || name == "lockWake",
              let info = {
                  if case .connected(let info) = inputClient.state { return info }
                  return nil
              }() else {
            recordInvalidMessage(context: context, code: "invalid_command", message: "控制命令无效。")
            return
        }
        guard validateSession(touch: true, context: context) else { return }
        let mask: UInt8 = name == "home" ? 4 : 2
        let x = info.framebufferWidth / 2
        let y = info.framebufferHeight / 2
        inputClient.sendPointer(mask: mask, x: x, y: y)
        inputClient.sendPointer(mask: 0, x: x, y: y)
        invalidMessageCount = 0
    }

    private func accept(sequence: UInt32) -> Bool {
        guard let lastSequence else {
            self.lastSequence = sequence
            return true
        }
        let distance = sequence &- lastSequence
        guard distance != 0, distance < 0x8000_0000 else { return false }
        self.lastSequence = sequence
        return true
    }

    private func sendRecoverableError(
        context: ChannelHandlerContext,
        code: String,
        message: String
    ) {
        WebSocketWire.sendJSON(errorObject(code: code, message: message, recoverable: true), context: context)
    }

    private func recordInvalidMessage(
        context: ChannelHandlerContext,
        code: String,
        message: String
    ) {
        invalidMessageCount += 1
        WebSocketWire.sendJSON(
            errorObject(code: code, message: message, recoverable: invalidMessageCount < 3),
            context: context
        )
        if invalidMessageCount >= 3 {
            releaseAllInputs()
            WebSocketWire.close(context: context, code: 1008, reason: "invalid protocol message")
        }
    }

    private func errorObject(code: String, message: String, recoverable: Bool) -> [String: Any] {
        [
            "v": 1,
            "type": "error",
            "code": code,
            "message": message,
            "recoverable": recoverable
        ]
    }

    private func releaseAllInputs() {
        cancelPendingMove()
        activePointerMask = 0
        lastPointerPoint = nil
        pressedKeysymsByCode.removeAll(keepingCapacity: false)
        inputClient.releaseAllInputs()
        releaseMicrophone(context: context, notify: false)
    }

    private func cleanUp() {
        guard !cleanedUp else { return }
        cleanedUp = true
        sessionTask?.cancel()
        sessionTask = nil
        microphoneWatchdog?.cancel()
        microphoneWatchdog = nil
        controllers.unregister(identifier: leaseIdentifier)
        _ = auth.releaseControllerLease(token: sessionToken, identifier: leaseIdentifier)
        releaseAllInputs()
        context = nil
    }

    private func enqueueMove(
        mask: UInt8,
        point: (x: UInt16, y: UInt16),
        context: ChannelHandlerContext
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let minimumInterval: UInt64 = 1_000_000_000 / 60
        let elapsed = now &- min(now, lastMoveSentAtNanoseconds)
        if moveTask == nil, elapsed >= minimumInterval {
            lastMoveSentAtNanoseconds = now
            inputClient.sendPointer(mask: mask, x: point.x, y: point.y)
            return
        }

        pendingMove = (mask, point.x, point.y)
        guard moveTask == nil else { return }
        let remaining = minimumInterval > elapsed ? minimumInterval - elapsed : 0
        moveTask = context.eventLoop.scheduleTask(in: .nanoseconds(Int64(clamping: remaining))) { [weak self] in
            guard let self else { return }
            moveTask = nil
            guard let pendingMove, activePointerMask != 0 else {
                self.pendingMove = nil
                return
            }
            self.pendingMove = nil
            lastMoveSentAtNanoseconds = DispatchTime.now().uptimeNanoseconds
            inputClient.sendPointer(
                mask: pendingMove.mask,
                x: pendingMove.x,
                y: pendingMove.y
            )
        }
    }

    private func cancelPendingMove() {
        moveTask?.cancel()
        moveTask = nil
        pendingMove = nil
    }

    private static func coordinate(_ normalized: Double, extent: UInt16) -> UInt16 {
        let maximum = max(0, Int(extent) - 1)
        return UInt16(clamping: min(max(Int(floor(normalized * Double(extent))), 0), maximum))
    }

    private static func rfbMask(browserButtons: UInt8) -> UInt8 {
        var mask: UInt8 = 0
        if browserButtons & 1 != 0 { mask |= 1 }
        if browserButtons & 2 != 0 { mask |= 4 }
        if browserButtons & 4 != 0 { mask |= 2 }
        return mask
    }

    private static func keysym(code: String, key: String) -> UInt32? {
        let named: [String: UInt32] = [
            "Backspace": 0xFF08, "Tab": 0xFF09, "Enter": 0xFF0D,
            "Escape": 0xFF1B, "Home": 0xFF50, "ArrowLeft": 0xFF51,
            "ArrowUp": 0xFF52, "ArrowRight": 0xFF53, "ArrowDown": 0xFF54,
            "PageUp": 0xFF55, "PageDown": 0xFF56, "End": 0xFF57,
            "Insert": 0xFF63, "Delete": 0xFFFF, " ": 0x20
        ]
        if let value = named[key] { return value }
        let modifiers: [String: UInt32] = [
            "ShiftLeft": 0xFFE1, "ShiftRight": 0xFFE2,
            "ControlLeft": 0xFFE3, "ControlRight": 0xFFE4,
            "MetaLeft": 0xFFE7, "MetaRight": 0xFFE8,
            "AltLeft": 0xFFE9, "AltRight": 0xFFEA
        ]
        if let value = modifiers[code] { return value }
        if code.hasPrefix("F"), let number = Int(code.dropFirst()), (1...12).contains(number) {
            return 0xFFBD + UInt32(number)
        }
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first else { return nil }
        if scalar.value <= 0xFF { return scalar.value }
        guard scalar.value <= 0x10FFFF else { return nil }
        return 0x0100_0000 | scalar.value
    }
}

private enum WebSocketValue {
    static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    static func integer(_ value: Any?) -> Int? {
        guard let double = finiteDouble(value),
              double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return Int(double)
    }

    static func uint32(_ value: Any?) -> UInt32? {
        guard let double = finiteDouble(value),
              double.rounded(.towardZero) == double,
              double >= 0, double <= Double(UInt32.max) else { return nil }
        return UInt32(double)
    }

    static func uint8(_ value: Any?) -> UInt8? {
        guard let double = finiteDouble(value),
              double.rounded(.towardZero) == double,
              double >= 0, double <= Double(UInt8.max) else { return nil }
        return UInt8(double)
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

private struct MessageRateWindow {
    private var windowStartNanoseconds: UInt64 = 0
    private var count = 0

    mutating func allow(maximum: Int) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if windowStartNanoseconds == 0 || now - windowStartNanoseconds >= 1_000_000_000 {
            windowStartNanoseconds = now
            count = 0
        }
        guard count < maximum else { return false }
        count += 1
        return true
    }
}
