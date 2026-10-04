import Foundation

enum WebCapacity {
    // One hardware encoder fans out to every viewer. Per-viewer backpressure
    // remains bounded in WebVideoSocketHandler, so normal viewers do not add
    // encoder load or block one another.
    static let maximumSessions = 16
    static let maximumViewers = 16
}

protocol WebVideoSink: AnyObject {
    func offer(configuration: H264StreamConfiguration)
    func offer(accessUnit: H264AccessUnit)
    func closeForServerShutdown()
}

final class WebVideoHub: @unchecked Sendable {
    var requestKeyFrame: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var sinks: [ObjectIdentifier: WebVideoSink] = [:]
    private var latestConfiguration: H264StreamConfiguration?

    @discardableResult
    func register(_ sink: WebVideoSink) -> Bool {
        lock.lock()
        guard sinks.count < WebCapacity.maximumViewers else {
            lock.unlock()
            return false
        }
        let configuration = latestConfiguration
        // Queue the retained decoder configuration before making this sink
        // visible to the live publisher. Otherwise an encoder callback can
        // publish a key frame in the gap between insertion and the deferred
        // configuration offer, violating the UDS config-before-media contract.
        if let configuration {
            sink.offer(configuration: configuration)
        }
        sinks[ObjectIdentifier(sink)] = sink
        lock.unlock()
        requestKeyFrame?()
        return true
    }

    func unregister(_ sink: WebVideoSink) {
        lock.lock()
        sinks.removeValue(forKey: ObjectIdentifier(sink))
        lock.unlock()
    }

    func publish(configuration: H264StreamConfiguration) {
        lock.lock()
        latestConfiguration = configuration
        let currentSinks = Array(sinks.values)
        lock.unlock()
        currentSinks.forEach { $0.offer(configuration: configuration) }
    }

    func publish(accessUnit: H264AccessUnit) {
        lock.lock()
        let currentSinks = Array(sinks.values)
        lock.unlock()
        currentSinks.forEach { $0.offer(accessUnit: accessUnit) }
    }

    func resendConfiguration(to sink: WebVideoSink) {
        lock.lock()
        let configuration = latestConfiguration
        lock.unlock()
        if let configuration {
            sink.offer(configuration: configuration)
        }
        requestKeyFrame?()
    }

    func closeAll() {
        lock.lock()
        let currentSinks = Array(sinks.values)
        sinks.removeAll(keepingCapacity: false)
        latestConfiguration = nil
        lock.unlock()
        currentSinks.forEach { $0.closeForServerShutdown() }
    }
}
