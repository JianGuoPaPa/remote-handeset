import Foundation

protocol WebAudioSink: AnyObject {
    func offer(configuration: OpusStreamConfiguration)
    func offer(packet: OpusAudioPacket)
    func closeForServerShutdown()
}

/// Shared by the Opus and PCM hubs so opening both endpoints cannot bypass the
/// overall audio-viewer limit.
final class WebAudioViewerCapacity: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var count = 0

    init(limit: Int = WebCapacity.maximumViewers) {
        self.limit = max(1, limit)
    }

    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count < limit else { return false }
        count += 1
        return true
    }

    func release(_ amount: Int = 1) {
        guard amount > 0 else { return }
        lock.lock()
        count = max(0, count - amount)
        lock.unlock()
    }
}

/// Fans one Opus encoder out to independent browser playback queues. The hub
/// never waits for a socket; each sink owns and bounds its own backpressure.
final class WebAudioHub: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: WebAudioViewerCapacity
    private var sinks: [ObjectIdentifier: WebAudioSink] = [:]
    private var latestConfiguration: OpusStreamConfiguration?

    init(capacity: WebAudioViewerCapacity = WebAudioViewerCapacity()) {
        self.capacity = capacity
    }

    @discardableResult
    func register(_ sink: WebAudioSink) -> Bool {
        guard capacity.acquire() else { return false }
        lock.lock()
        let identifier = ObjectIdentifier(sink)
        guard sinks[identifier] == nil else {
            lock.unlock()
            capacity.release()
            return true
        }
        let configuration = latestConfiguration
        // Queue the retained stream configuration while publication is still
        // excluded. If the sink becomes visible first, a concurrent encoder
        // callback can enqueue Opus before the configuration and force the UDS
        // receiver to reject an otherwise valid connection.
        if let configuration {
            sink.offer(configuration: configuration)
        }
        sinks[identifier] = sink
        lock.unlock()
        return true
    }

    func unregister(_ sink: WebAudioSink) {
        lock.lock()
        let removed = sinks.removeValue(forKey: ObjectIdentifier(sink)) != nil
        lock.unlock()
        if removed { capacity.release() }
    }

    func publish(configuration: OpusStreamConfiguration) {
        lock.lock()
        latestConfiguration = configuration
        let currentSinks = Array(sinks.values)
        lock.unlock()
        currentSinks.forEach { $0.offer(configuration: configuration) }
    }

    func publish(packet: OpusAudioPacket) {
        lock.lock()
        let currentSinks = Array(sinks.values)
        lock.unlock()
        currentSinks.forEach { $0.offer(packet: packet) }
    }

    func resendConfiguration(to sink: WebAudioSink) {
        lock.lock()
        let configuration = latestConfiguration
        lock.unlock()
        if let configuration {
            sink.offer(configuration: configuration)
        }
    }

    func closeAll() {
        lock.lock()
        let currentSinks = Array(sinks.values)
        let releasedCount = sinks.count
        sinks.removeAll(keepingCapacity: false)
        latestConfiguration = nil
        lock.unlock()
        capacity.release(releasedCount)
        currentSinks.forEach { $0.closeForServerShutdown() }
    }
}
