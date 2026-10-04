import Darwin
import Foundation
import NIOCore
import NIOPosix

/// Binary framing shared by the three private Unix-domain sockets.
/// All integer fields are network byte order and every message is complete.
private enum DriverWire {
    static let magic = "IUSD"
    static let version: UInt8 = 1
    static let headerLength: UInt16 = 32
    static let maximumControlPayload = 64 * 1_024

    enum Stream: UInt8 {
        case video = 1
        case audio = 2
        case control = 3
    }

    enum VideoMessage: UInt8 {
        case configuration = 1
        case accessUnit = 2
    }

    enum AudioMessage: UInt8 {
        case configuration = 1
        case packet = 2
    }

    enum ControlMessage: UInt8 {
        case requestKeyFrame = 1
        case ping = 2
        case hello = 0x81
        case pong = 0x82
        case error = 0xff
    }

    static func encode(
        allocator: ByteBufferAllocator,
        stream: Stream,
        type: UInt8,
        flags: UInt8 = 0,
        timestamp: UInt64 = 0,
        sequence: UInt32 = 0,
        auxiliary: UInt32 = 0,
        payload: Data = Data()
    ) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: Int(headerLength) + payload.count)
        buffer.writeString(magic)
        buffer.writeInteger(version)
        buffer.writeInteger(stream.rawValue)
        buffer.writeInteger(type)
        buffer.writeInteger(flags)
        buffer.writeInteger(headerLength, endianness: .big)
        buffer.writeInteger(UInt16(0), endianness: .big)
        buffer.writeInteger(UInt32(clamping: payload.count), endianness: .big)
        buffer.writeInteger(timestamp, endianness: .big)
        buffer.writeInteger(sequence, endianness: .big)
        buffer.writeInteger(auxiliary, endianness: .big)
        buffer.writeBytes(payload)
        return buffer
    }

    static func json(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

final class UnixMediaSocketServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    var onStateChange: (@Sendable (State) -> Void)?
    var onKeyFrameRequested: (@Sendable () -> Void)?

    private let videoSocketURL: URL
    private let audioSocketURL: URL
    private let controlSocketURL: URL
    private let lifecycleQueue = DispatchQueue(
        label: "local.iphone.usbdriver.socket-lifecycle",
        qos: .userInitiated
    )
    private let lifecycleQueueKey = DispatchSpecificKey<UInt8>()
    private let stateLock = NSLock()
    private let videoHub = WebVideoHub()
    private let audioHub = WebAudioHub(capacity: WebAudioViewerCapacity(limit: 4))

    private var storedState: State = .stopped
    private var desiredRunning = false
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var channels: [Channel] = []

    init(videoSocketURL: URL, audioSocketURL: URL, controlSocketURL: URL) {
        self.videoSocketURL = videoSocketURL
        self.audioSocketURL = audioSocketURL
        self.controlSocketURL = controlSocketURL
        lifecycleQueue.setSpecific(key: lifecycleQueueKey, value: 1)
        videoHub.requestKeyFrame = { [weak self] in self?.onKeyFrameRequested?() }
    }

    deinit {
        stop()
    }

    func start() {
        stateLock.lock()
        guard !desiredRunning else {
            stateLock.unlock()
            return
        }
        desiredRunning = true
        storedState = .starting
        stateLock.unlock()
        notify(.starting)
        lifecycleQueue.async { [weak self] in self?.performStart() }
    }

    func stop() {
        stateLock.lock()
        desiredRunning = false
        stateLock.unlock()

        let work = { [weak self] in self?.performStop() }
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil {
            work()
        } else {
            lifecycleQueue.sync(execute: work)
        }
    }

    func publish(videoConfiguration configuration: H264StreamConfiguration) {
        videoHub.publish(configuration: configuration)
    }

    func publish(videoAccessUnit accessUnit: H264AccessUnit) {
        videoHub.publish(accessUnit: accessUnit)
    }

    func publish(audioConfiguration configuration: OpusStreamConfiguration) {
        audioHub.publish(configuration: configuration)
    }

    func publish(audioPacket packet: OpusAudioPacket) {
        audioHub.publish(packet: packet)
    }

    private func performStart() {
        var provisionalGroup: MultiThreadedEventLoopGroup?
        var provisionalChannels: [Channel] = []
        do {
            let socketURLs = [videoSocketURL, audioSocketURL, controlSocketURL]
            try prepareSocketDirectoryAndRemoveStaleSockets(socketURLs)

            let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
            provisionalGroup = group
            let videoHub = self.videoHub
            let audioHub = self.audioHub
            let requestKeyFrame: @Sendable () -> Void = { [weak self] in
                self?.onKeyFrameRequested?()
            }

            let videoChannel = try bootstrap(group: group) { channel in
                channel.pipeline.addHandler(UnixVideoChannelHandler(hub: videoHub))
            }.bind(unixDomainSocketPath: videoSocketURL.path).wait()
            provisionalChannels.append(videoChannel)
            try secureSocket(at: videoSocketURL)

            let audioChannel = try bootstrap(group: group) { channel in
                channel.pipeline.addHandler(UnixAudioChannelHandler(hub: audioHub))
            }.bind(unixDomainSocketPath: audioSocketURL.path).wait()
            provisionalChannels.append(audioChannel)
            try secureSocket(at: audioSocketURL)

            let controlChannel = try bootstrap(group: group) { channel in
                channel.pipeline.addHandler(UnixControlChannelHandler(
                    requestKeyFrame: requestKeyFrame
                ))
            }.bind(unixDomainSocketPath: controlSocketURL.path).wait()
            provisionalChannels.append(controlChannel)
            try secureSocket(at: controlSocketURL)

            stateLock.lock()
            guard desiredRunning else {
                stateLock.unlock()
                provisionalChannels.forEach { try? $0.close().wait() }
                try? group.syncShutdownGracefully()
                removeOwnedSockets(socketURLs)
                return
            }
            eventLoopGroup = group
            channels = provisionalChannels
            storedState = .running
            stateLock.unlock()
            provisionalGroup = nil
            provisionalChannels.removeAll(keepingCapacity: false)
            notify(.running)
        } catch {
            provisionalChannels.forEach { try? $0.close().wait() }
            try? provisionalGroup?.syncShutdownGracefully()
            removeOwnedSockets([videoSocketURL, audioSocketURL, controlSocketURL])
            stateLock.lock()
            desiredRunning = false
            storedState = .failed(error.localizedDescription)
            stateLock.unlock()
            notify(.failed(error.localizedDescription))
        }
    }

    private func performStop() {
        stateLock.lock()
        let channels = self.channels
        self.channels = []
        let group = eventLoopGroup
        eventLoopGroup = nil
        storedState = .stopped
        stateLock.unlock()

        videoHub.closeAll()
        audioHub.closeAll()
        channels.forEach { try? $0.close().wait() }
        try? group?.syncShutdownGracefully()
        removeOwnedSockets([videoSocketURL, audioSocketURL, controlSocketURL])
        notify(.stopped)
    }

    private func bootstrap(
        group: MultiThreadedEventLoopGroup,
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> ServerBootstrap {
        ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 8)
            .childChannelInitializer(initializer)
            .childChannelOption(.maxMessagesPerRead, value: 16)
            .childChannelOption(.writeSpin, value: 8)
            .childChannelOption(
                ChannelOptions.writeBufferWaterMark,
                value: ChannelOptions.Types.WriteBufferWaterMark(
                    low: 256 * 1_024,
                    high: 1_024 * 1_024
                )
            )
    }

    private func prepareSocketDirectoryAndRemoveStaleSockets(_ socketURLs: [URL]) throws {
        guard let directory = socketURLs.first?.deletingLastPathComponent(),
              socketURLs.allSatisfy({ $0.deletingLastPathComponent() == directory }) else {
            throw SocketServerError.invalidSocketDirectory
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        for url in socketURLs {
            guard url.isFileURL, url.path.utf8.count <= 103 else {
                throw SocketServerError.invalidSocketPath
            }
            try removeOwnedSocketIfPresent(url)
        }
    }

    private func secureSocket(at url: URL) throws {
        guard chmod(url.path, 0o600) == 0 else {
            throw SocketServerError.posix(operation: "chmod", code: errno)
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFSOCK,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & 0o777) == 0o600 else {
            throw SocketServerError.insecureSocket
        }
    }

    private func removeOwnedSocketIfPresent(_ url: URL) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw SocketServerError.posix(operation: "lstat", code: errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFSOCK,
              metadata.st_uid == geteuid() else {
            throw SocketServerError.refusedUnsafeRemoval
        }
        guard unlink(url.path) == 0 else {
            throw SocketServerError.posix(operation: "unlink", code: errno)
        }
    }

    private func removeOwnedSockets(_ urls: [URL]) {
        for url in urls { try? removeOwnedSocketIfPresent(url) }
    }

    private func notify(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }
}

private enum SocketServerError: Error, LocalizedError {
    case invalidSocketDirectory
    case invalidSocketPath
    case insecureSocket
    case refusedUnsafeRemoval
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidSocketDirectory: return "socket_directory_invalid"
        case .invalidSocketPath: return "socket_path_invalid"
        case .insecureSocket: return "socket_permissions_invalid"
        case .refusedUnsafeRemoval: return "socket_existing_path_refused"
        case .posix(let operation, let code): return "\(operation)_errno_\(code)"
        }
    }
}

private final class UnixVideoChannelHandler: ChannelInboundHandler, WebVideoSink, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let hub: WebVideoHub
    private var context: ChannelHandlerContext?
    private var registered = false
    private var writeInFlight = false
    private var writeDeadline: Scheduled<Void>?
    private var pendingConfiguration: H264StreamConfiguration?
    private var pendingAccessUnit: H264AccessUnit?
    private var requiresKeyFrame = true
    private var keyFrameRequested = false

    init(hub: WebVideoHub) {
        self.hub = hub
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func channelActive(context: ChannelHandlerContext) {
        registered = hub.register(self)
        guard registered else {
            context.close(promise: nil)
            return
        }
        context.fireChannelActive()
    }

    func handlerRemoved(context: ChannelHandlerContext) { cleanUp() }

    func channelInactive(context: ChannelHandlerContext) {
        cleanUp()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Video is an output-only socket. Any inbound bytes indicate that the
        // peer selected the wrong endpoint.
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        drain(context: context)
        context.fireChannelWritabilityChanged()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func offer(configuration: H264StreamConfiguration) {
        guard let context else { return }
        context.eventLoop.execute { [weak self, weak context] in
            guard let self, let context, context.channel.isActive else { return }
            pendingConfiguration = configuration
            pendingAccessUnit = nil
            requiresKeyFrame = true
            keyFrameRequested = false
            drain(context: context)
        }
    }

    func offer(accessUnit: H264AccessUnit) {
        guard let context else { return }
        context.eventLoop.execute { [weak self, weak context] in
            guard let self, let context, context.channel.isActive else { return }
            if requiresKeyFrame, !accessUnit.isKeyFrame {
                requestKeyFrameIfNeeded()
                return
            }
            guard !writeInFlight, context.channel.isWritable,
                  pendingConfiguration == nil else {
                if pendingAccessUnit == nil {
                    pendingAccessUnit = accessUnit
                } else if pendingAccessUnit?.isKeyFrame != true {
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
        context.eventLoop.execute { [weak context] in context?.close(promise: nil) }
    }

    private func drain(context: ChannelHandlerContext) {
        guard !writeInFlight, context.channel.isWritable else { return }
        if let configuration = pendingConfiguration {
            pendingConfiguration = nil
            send(configuration: configuration, context: context)
            return
        }
        guard let accessUnit = pendingAccessUnit else { return }
        pendingAccessUnit = nil
        guard !requiresKeyFrame || accessUnit.isKeyFrame else {
            requestKeyFrameIfNeeded()
            return
        }
        send(accessUnit: accessUnit, context: context)
    }

    private func send(configuration: H264StreamConfiguration, context: ChannelHandlerContext) {
        guard let payload = DriverWire.json([
            "codec": configuration.codec,
            "codedWidth": configuration.codedWidth,
            "codedHeight": configuration.codedHeight,
            "description": configuration.avcDecoderConfigurationRecord.base64EncodedString()
        ]) else {
            context.close(promise: nil)
            return
        }
        let buffer = DriverWire.encode(
            allocator: context.channel.allocator,
            stream: .video,
            type: DriverWire.VideoMessage.configuration.rawValue,
            payload: payload
        )
        write(buffer, context: context)
        requestKeyFrameIfNeeded()
    }

    private func send(accessUnit: H264AccessUnit, context: ChannelHandlerContext) {
        if accessUnit.isKeyFrame {
            requiresKeyFrame = false
            keyFrameRequested = false
        }
        let buffer = DriverWire.encode(
            allocator: context.channel.allocator,
            stream: .video,
            type: DriverWire.VideoMessage.accessUnit.rawValue,
            flags: accessUnit.isKeyFrame ? 1 : 0,
            timestamp: accessUnit.timestampMicroseconds,
            sequence: accessUnit.sequence,
            payload: accessUnit.avccData
        )
        write(buffer, context: context)
    }

    private func write(_ buffer: ByteBuffer, context: ChannelHandlerContext) {
        writeInFlight = true
        let promise = context.eventLoop.makePromise(of: Void.self)
        let deadline: Scheduled<Void> = context.eventLoop.scheduleTask(in: .seconds(2)) {
            [weak context] in
            if let context { context.close(promise: nil) }
        }
        writeDeadline = deadline
        promise.futureResult.whenComplete { [weak self, weak context] _ in
            guard let self, let context else { return }
            writeDeadline?.cancel()
            writeDeadline = nil
            writeInFlight = false
            drain(context: context)
        }
        context.writeAndFlush(wrapOutboundOut(buffer), promise: promise)
    }

    private func requestKeyFrameIfNeeded() {
        guard !keyFrameRequested else { return }
        keyFrameRequested = true
        hub.requestKeyFrame?()
    }

    private func cleanUp() {
        writeDeadline?.cancel()
        writeDeadline = nil
        pendingConfiguration = nil
        pendingAccessUnit = nil
        context = nil
        if registered {
            registered = false
            hub.unregister(self)
        }
    }
}

private final class UnixAudioChannelHandler: ChannelInboundHandler, WebAudioSink, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let hub: WebAudioHub
    private var context: ChannelHandlerContext?
    private var registered = false
    private var writeInFlight = false
    private var writeDeadline: Scheduled<Void>?
    private var pendingConfiguration: OpusStreamConfiguration?
    private var pendingPacket: OpusAudioPacket?

    init(hub: WebAudioHub) {
        self.hub = hub
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func channelActive(context: ChannelHandlerContext) {
        registered = hub.register(self)
        guard registered else {
            context.close(promise: nil)
            return
        }
        context.fireChannelActive()
    }

    func handlerRemoved(context: ChannelHandlerContext) { cleanUp() }

    func channelInactive(context: ChannelHandlerContext) {
        cleanUp()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        drain(context: context)
        context.fireChannelWritabilityChanged()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func offer(configuration: OpusStreamConfiguration) {
        guard let context else { return }
        context.eventLoop.execute { [weak self, weak context] in
            guard let self, let context, context.channel.isActive else { return }
            pendingConfiguration = configuration
            pendingPacket = nil
            drain(context: context)
        }
    }

    func offer(packet: OpusAudioPacket) {
        guard let context else { return }
        context.eventLoop.execute { [weak self, weak context] in
            guard let self, let context, context.channel.isActive else { return }
            guard !writeInFlight, context.channel.isWritable,
                  pendingConfiguration == nil else {
                pendingPacket = packet.markingDiscontinuity()
                return
            }
            send(packet: packet, context: context)
        }
    }

    func closeForServerShutdown() {
        guard let context else { return }
        context.eventLoop.execute { [weak context] in context?.close(promise: nil) }
    }

    private func drain(context: ChannelHandlerContext) {
        guard !writeInFlight, context.channel.isWritable else { return }
        if let configuration = pendingConfiguration {
            pendingConfiguration = nil
            send(configuration: configuration, context: context)
            return
        }
        if let packet = pendingPacket {
            pendingPacket = nil
            send(packet: packet, context: context)
        }
    }

    private func send(configuration: OpusStreamConfiguration, context: ChannelHandlerContext) {
        guard let payload = DriverWire.json([
            "codec": configuration.codec,
            "sampleRate": configuration.sampleRate,
            "channels": configuration.numberOfChannels,
            "frameDurationUs": configuration.frameDurationMicroseconds
        ]) else {
            context.close(promise: nil)
            return
        }
        let buffer = DriverWire.encode(
            allocator: context.channel.allocator,
            stream: .audio,
            type: DriverWire.AudioMessage.configuration.rawValue,
            payload: payload
        )
        write(buffer, context: context)
    }

    private func send(packet: OpusAudioPacket, context: ChannelHandlerContext) {
        let buffer = DriverWire.encode(
            allocator: context.channel.allocator,
            stream: .audio,
            type: DriverWire.AudioMessage.packet.rawValue,
            flags: packet.discontinuity ? 1 : 0,
            timestamp: packet.timestampMicroseconds,
            sequence: packet.sequence,
            auxiliary: UInt32(packet.frameCount),
            payload: packet.payload
        )
        write(buffer, context: context)
    }

    private func write(_ buffer: ByteBuffer, context: ChannelHandlerContext) {
        writeInFlight = true
        let promise = context.eventLoop.makePromise(of: Void.self)
        let deadline: Scheduled<Void> = context.eventLoop.scheduleTask(in: .seconds(2)) {
            [weak context] in
            if let context { context.close(promise: nil) }
        }
        writeDeadline = deadline
        promise.futureResult.whenComplete { [weak self, weak context] _ in
            guard let self, let context else { return }
            writeDeadline?.cancel()
            writeDeadline = nil
            writeInFlight = false
            drain(context: context)
        }
        context.writeAndFlush(wrapOutboundOut(buffer), promise: promise)
    }

    private func cleanUp() {
        writeDeadline?.cancel()
        writeDeadline = nil
        pendingConfiguration = nil
        pendingPacket = nil
        context = nil
        if registered {
            registered = false
            hub.unregister(self)
        }
    }
}

private final class UnixControlChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let requestKeyFrame: @Sendable () -> Void
    private var inbound = ByteBuffer()

    init(requestKeyFrame: @escaping @Sendable () -> Void) {
        self.requestKeyFrame = requestKeyFrame
    }

    func handlerAdded(context: ChannelHandlerContext) {
        guard let payload = DriverWire.json([
            "role": "iphone-usb-media-driver",
            "version": 1,
            "input": "gateway-direct-rfb"
        ]) else {
            context.close(promise: nil)
            return
        }
        let hello = DriverWire.encode(
            allocator: context.channel.allocator,
            stream: .control,
            type: DriverWire.ControlMessage.hello.rawValue,
            payload: payload
        )
        context.writeAndFlush(wrapOutboundOut(hello), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        inbound.writeBuffer(&incoming)
        guard inbound.readableBytes <= DriverWire.maximumControlPayload + Int(DriverWire.headerLength)
        else {
            context.close(promise: nil)
            return
        }

        while parseOne(context: context) {}
        inbound.discardReadBytes()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func parseOne(context: ChannelHandlerContext) -> Bool {
        let start = inbound.readerIndex
        guard inbound.readableBytes >= Int(DriverWire.headerLength) else { return false }
        guard let magic = inbound.readString(length: 4),
              let version: UInt8 = inbound.readInteger(),
              let stream: UInt8 = inbound.readInteger(),
              let type: UInt8 = inbound.readInteger(),
              let _: UInt8 = inbound.readInteger(),
              let headerLength: UInt16 = inbound.readInteger(endianness: .big),
              let _: UInt16 = inbound.readInteger(endianness: .big),
              let payloadLength: UInt32 = inbound.readInteger(endianness: .big),
              let timestamp: UInt64 = inbound.readInteger(endianness: .big),
              let sequence: UInt32 = inbound.readInteger(endianness: .big),
              let _: UInt32 = inbound.readInteger(endianness: .big),
              magic == DriverWire.magic,
              version == DriverWire.version,
              stream == DriverWire.Stream.control.rawValue,
              headerLength == DriverWire.headerLength,
              payloadLength <= DriverWire.maximumControlPayload else {
            context.close(promise: nil)
            return false
        }
        guard inbound.readableBytes >= Int(payloadLength) else {
            inbound.moveReaderIndex(to: start)
            return false
        }
        _ = inbound.readSlice(length: Int(payloadLength))

        switch type {
        case DriverWire.ControlMessage.requestKeyFrame.rawValue:
            requestKeyFrame()
        case DriverWire.ControlMessage.ping.rawValue:
            let pong = DriverWire.encode(
                allocator: context.channel.allocator,
                stream: .control,
                type: DriverWire.ControlMessage.pong.rawValue,
                timestamp: timestamp,
                sequence: sequence
            )
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        default:
            let error = DriverWire.encode(
                allocator: context.channel.allocator,
                stream: .control,
                type: DriverWire.ControlMessage.error.rawValue,
                sequence: sequence,
                payload: Data("unsupported_command".utf8)
            )
            context.writeAndFlush(wrapOutboundOut(error), promise: nil)
        }
        return true
    }
}
