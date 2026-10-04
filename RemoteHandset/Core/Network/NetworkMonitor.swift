import Foundation
import Network

final class NetworkMonitor {
    enum Interface: String {
        case wifi = "Wi-Fi"
        case cellular = "蜂窝网络"
        case wired = "有线网络"
        case other = "其他网络"
        case unavailable = "网络不可用"
    }

    struct Snapshot: Equatable {
        let isSatisfied: Bool
        let interface: Interface
        let isExpensive: Bool
        let isConstrained: Bool
    }

    var onChange: ((Snapshot, Snapshot?) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.dltengwen.remotehandset.path-monitor")
    private var lastSnapshot: Snapshot?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let snapshot = Snapshot(
                isSatisfied: path.status == .satisfied,
                interface: Self.interface(for: path),
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            let previous = self.lastSnapshot
            self.lastSnapshot = snapshot
            guard snapshot != previous else { return }
            DispatchQueue.main.async {
                self.onChange?(snapshot, previous)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    private static func interface(for path: NWPath) -> Interface {
        if path.status != .satisfied { return .unavailable }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }
}

