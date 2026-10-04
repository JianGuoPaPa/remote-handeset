import Foundation
import NIOCore

struct WebConsoleStatusSnapshot: Sendable {
    let usbVideoState: String
    let usbVideoConnected: Bool
    let fps: Double?
    let frameAgeMilliseconds: Double?
    let controlState: String
    let controlConnected: Bool
    let deviceName: String
    let framebufferWidth: UInt16?
    let framebufferHeight: UInt16?

    var statusJSONObject: [String: Any] {
        [
            "usbVideo": [
                "state": usbVideoState,
                "connected": usbVideoConnected,
                "fps": Self.jsonNumber(fps),
                "frameAgeMs": Self.jsonNumber(frameAgeMilliseconds)
            ],
            "control": [
                "state": controlState,
                "connected": controlConnected
            ],
            "device": [
                "name": deviceName
            ]
        ]
    }

    var controlStateJSONObject: [String: Any] {
        [
            "v": 1,
            "type": "state",
            "control": controlState,
            "usbVideo": usbVideoState,
            "deviceName": deviceName,
            "width": Self.jsonInteger(framebufferWidth),
            "height": Self.jsonInteger(framebufferHeight)
        ]
    }

    private static func jsonNumber(_ value: Double?) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        return value
    }

    private static func jsonInteger(_ value: UInt16?) -> Any {
        guard let value else { return NSNull() }
        return Int(value)
    }
}

final class WebConsoleStatusStore: @unchecked Sendable {
    var onChange: (@Sendable (WebConsoleStatusSnapshot) -> Void)?

    private let lock = NSLock()
    private var usbVideoState = "disconnected"
    private var usbVideoConnected = false
    private var fps: Double?
    private var frameAgeMilliseconds: Double?
    private var controlState = "disconnected"
    private var controlConnected = false
    private var deviceName = "iPhone (USB)"
    private var framebufferWidth: UInt16?
    private var framebufferHeight: UInt16?

    func updateCapture(
        state: String,
        connected: Bool,
        fps: Double?,
        frameAgeMilliseconds: Double?,
        deviceName: String?
    ) {
        lock.lock()
        usbVideoState = state
        usbVideoConnected = connected
        self.fps = fps.flatMap { $0.isFinite ? $0 : nil }
        self.frameAgeMilliseconds = frameAgeMilliseconds.flatMap { $0.isFinite ? $0 : nil }
        if let deviceName, !deviceName.isEmpty {
            self.deviceName = deviceName
        }
        let snapshot = snapshotLocked()
        lock.unlock()
        onChange?(snapshot)
    }

    func updateControl(state: String, connected: Bool, serverInfo: RFBInputClient.ServerInfo?) {
        lock.lock()
        controlState = state
        controlConnected = connected
        framebufferWidth = serverInfo?.framebufferWidth
        framebufferHeight = serverInfo?.framebufferHeight
        let snapshot = snapshotLocked()
        lock.unlock()
        onChange?(snapshot)
    }

    func snapshot() -> WebConsoleStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    private func snapshotLocked() -> WebConsoleStatusSnapshot {
        WebConsoleStatusSnapshot(
            usbVideoState: usbVideoState,
            usbVideoConnected: usbVideoConnected,
            fps: fps,
            frameAgeMilliseconds: frameAgeMilliseconds,
            controlState: controlState,
            controlConnected: controlConnected,
            deviceName: deviceName,
            framebufferWidth: framebufferWidth,
            framebufferHeight: framebufferHeight
        )
    }
}

protocol WebControlStateSink: AnyObject {
    func offer(status: WebConsoleStatusSnapshot)
    func closeForSessionExpiry()
}

final class WebControllerChannelRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [String: Channel] = [:]
    private var stateSinks: [String: WebControlStateSink] = [:]

    func register(identifier: String, channel: Channel, stateSink: WebControlStateSink) {
        lock.lock()
        channels[identifier] = channel
        stateSinks[identifier] = stateSink
        lock.unlock()
    }

    func unregister(identifier: String) {
        lock.lock()
        channels.removeValue(forKey: identifier)
        stateSinks.removeValue(forKey: identifier)
        lock.unlock()
    }

    func expire(identifier: String) {
        lock.lock()
        let sink = stateSinks[identifier]
        lock.unlock()
        sink?.closeForSessionExpiry()
    }

    func closeAll() {
        lock.lock()
        let currentChannels = Array(channels.values)
        channels.removeAll(keepingCapacity: false)
        stateSinks.removeAll(keepingCapacity: false)
        lock.unlock()
        for channel in currentChannels {
            channel.eventLoop.execute {
                channel.close(promise: nil)
            }
        }
    }

    func broadcast(status: WebConsoleStatusSnapshot) {
        lock.lock()
        let sinks = Array(stateSinks.values)
        lock.unlock()
        sinks.forEach { $0.offer(status: status) }
    }
}

enum WebConsoleJSON {
    static func data(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }
}
