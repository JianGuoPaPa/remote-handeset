import Foundation

final class SignalingSocket: NSObject {
    enum SocketError: LocalizedError {
        case invalidMessage
        case closed
        case heartbeatTimedOut

        var errorDescription: String? {
            switch self {
            case .invalidMessage:
                return "信令服务器返回了无法识别的数据"
            case .closed:
                return "信令连接已关闭"
            case .heartbeatTimedOut:
                return "信令连接心跳超时"
            }
        }
    }

    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var didOpen = false
    private var isClosing = false
    private var didNotifyClose = false
    private var heartbeatWorkItem: DispatchWorkItem?
    private var heartbeatTimeoutWorkItem: DispatchWorkItem?
    private var heartbeatInFlight = false
    private var heartbeatGeneration: UInt64 = 0
    private var consecutiveHeartbeatFailures = 0
    private let lifecycleLock = NSLock()
    private let heartbeatQueue = DispatchQueue(
        label: "com.dltengwen.remotehandset.signaling-heartbeat",
        qos: .utility
    )

    func connect(request: URLRequest) async throws {
        close()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)

        install(session: session, task: task)

        try await withCheckedThrowingContinuation { continuation in
            lifecycleLock.lock()
            openContinuation = continuation
            lifecycleLock.unlock()
            task.resume()
        }
        receiveNext()
    }

    func sendJSON(_ object: [String: Any]) async throws {
        guard let currentTask = currentTaskForSending() else {
            throw SocketError.closed
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SocketError.invalidMessage
        }
        try await currentTask.send(.string(text))
    }

    private func install(
        session: URLSession,
        task: URLSessionWebSocketTask
    ) {
        lifecycleLock.lock()
        isClosing = false
        didOpen = false
        didNotifyClose = false
        heartbeatInFlight = false
        heartbeatGeneration &+= 1
        consecutiveHeartbeatFailures = 0
        urlSession = session
        self.task = task
        lifecycleLock.unlock()
    }

    private func currentTaskForSending() -> URLSessionWebSocketTask? {
        lifecycleLock.lock()
        let currentTask = isClosing || didNotifyClose ? nil : task
        lifecycleLock.unlock()
        return currentTask
    }

    func close() {
        lifecycleLock.lock()
        isClosing = true
        didNotifyClose = true
        let continuation = openContinuation
        openContinuation = nil
        let currentTask = task
        task = nil
        let currentSession = urlSession
        urlSession = nil
        didOpen = false
        heartbeatInFlight = false
        heartbeatGeneration &+= 1
        consecutiveHeartbeatFailures = 0
        let heartbeat = heartbeatWorkItem
        heartbeatWorkItem = nil
        let heartbeatTimeout = heartbeatTimeoutWorkItem
        heartbeatTimeoutWorkItem = nil
        lifecycleLock.unlock()

        heartbeat?.cancel()
        heartbeatTimeout?.cancel()
        continuation?.resume(throwing: SocketError.closed)
        currentTask?.cancel(with: .goingAway, reason: nil)
        currentSession?.invalidateAndCancel()
    }

    private func receiveNext() {
        lifecycleLock.lock()
        let currentTask = isClosing || didNotifyClose ? nil : task
        lifecycleLock.unlock()
        guard let currentTask else { return }

        currentTask.receive { [weak self] result in
            guard let self else { return }
            self.lifecycleLock.lock()
            let isCurrent = self.task === currentTask
                && !self.isClosing
                && !self.didNotifyClose
            self.lifecycleLock.unlock()
            guard isCurrent else { return }
            switch result {
            case let .success(message):
                self.lifecycleLock.lock()
                self.consecutiveHeartbeatFailures = 0
                self.lifecycleLock.unlock()
                switch message {
                case let .string(text):
                    if let data = text.data(using: .utf8) {
                        self.onMessage?(data)
                    }
                case let .data(data):
                    self.onMessage?(data)
                @unknown default:
                    break
                }
                self.receiveNext()
            case let .failure(error):
                self.notifyClose(error)
            }
        }
    }

    private func startHeartbeat() {
        scheduleHeartbeat(after: AppConfiguration.signalingHeartbeatInterval)
    }

    private func scheduleHeartbeat(after interval: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.performHeartbeat()
        }

        lifecycleLock.lock()
        guard !isClosing, !didNotifyClose, didOpen else {
            lifecycleLock.unlock()
            return
        }
        heartbeatWorkItem?.cancel()
        heartbeatWorkItem = workItem
        lifecycleLock.unlock()

        heartbeatQueue.asyncAfter(
            deadline: .now() + interval,
            execute: workItem
        )
    }

    private func performHeartbeat() {
        lifecycleLock.lock()
        heartbeatWorkItem = nil
        guard !isClosing,
              !didNotifyClose,
              didOpen,
              !heartbeatInFlight,
              let currentTask = task
        else {
            lifecycleLock.unlock()
            return
        }
        heartbeatInFlight = true
        heartbeatGeneration &+= 1
        let generation = heartbeatGeneration
        lifecycleLock.unlock()

        let timeout = DispatchWorkItem { [weak self] in
            self?.heartbeatDidTimeOut(generation: generation)
        }
        lifecycleLock.lock()
        guard heartbeatInFlight,
              heartbeatGeneration == generation,
              !isClosing,
              !didNotifyClose
        else {
            lifecycleLock.unlock()
            return
        }
        heartbeatTimeoutWorkItem = timeout
        lifecycleLock.unlock()
        heartbeatQueue.asyncAfter(
            deadline: .now() + AppConfiguration.signalingHeartbeatTimeout,
            execute: timeout
        )

        currentTask.sendPing { [weak self] error in
            self?.finishHeartbeat(generation: generation, error: error)
        }
    }

    private func finishHeartbeat(generation: UInt64, error: Error?) {
        lifecycleLock.lock()
        guard heartbeatInFlight,
              heartbeatGeneration == generation,
              !isClosing,
              !didNotifyClose
        else {
            lifecycleLock.unlock()
            return
        }
        heartbeatInFlight = false
        let timeout = heartbeatTimeoutWorkItem
        heartbeatTimeoutWorkItem = nil
        if error == nil {
            consecutiveHeartbeatFailures = 0
        } else {
            consecutiveHeartbeatFailures += 1
        }
        let shouldClose = consecutiveHeartbeatFailures
            >= AppConfiguration.signalingHeartbeatFailureLimit
        let shouldContinue = didOpen && !shouldClose
        lifecycleLock.unlock()

        timeout?.cancel()
        if shouldClose {
            notifyClose(error)
        } else if shouldContinue {
            scheduleHeartbeat(after: AppConfiguration.signalingHeartbeatInterval)
        }
    }

    private func heartbeatDidTimeOut(generation: UInt64) {
        finishHeartbeat(
            generation: generation,
            error: SocketError.heartbeatTimedOut
        )
    }

    private func notifyClose(_ error: Error?) {
        lifecycleLock.lock()
        guard !isClosing, !didNotifyClose else {
            lifecycleLock.unlock()
            return
        }
        isClosing = true
        didNotifyClose = true
        didOpen = false
        let continuation = openContinuation
        openContinuation = nil
        let currentTask = task
        task = nil
        let currentSession = urlSession
        urlSession = nil
        let heartbeat = heartbeatWorkItem
        heartbeatWorkItem = nil
        let heartbeatTimeout = heartbeatTimeoutWorkItem
        heartbeatTimeoutWorkItem = nil
        heartbeatInFlight = false
        heartbeatGeneration &+= 1
        consecutiveHeartbeatFailures = 0
        lifecycleLock.unlock()

        heartbeat?.cancel()
        heartbeatTimeout?.cancel()
        continuation?.resume(throwing: error ?? SocketError.closed)
        currentTask?.cancel()
        currentSession?.invalidateAndCancel()
        onClose?(error)
    }

    private func completeOpening(with result: Result<Void, Error>) {
        lifecycleLock.lock()
        let continuation = openContinuation
        openContinuation = nil
        let effectiveResult: Result<Void, Error>
        if case .success = result, isClosing || didNotifyClose {
            effectiveResult = .failure(SocketError.closed)
        } else {
            effectiveResult = result
        }
        if case .success = effectiveResult {
            didOpen = true
        }
        lifecycleLock.unlock()

        switch effectiveResult {
        case .success:
            continuation?.resume()
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }
}

extension SignalingSocket: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lifecycleLock.lock()
        let isCurrent =
            task === webSocketTask && !isClosing && !didNotifyClose
        lifecycleLock.unlock()
        guard isCurrent else { return }
        completeOpening(with: .success(()))
        startHeartbeat()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        lifecycleLock.lock()
        let isCurrent = task === webSocketTask
        let wasOpen = didOpen
        lifecycleLock.unlock()
        guard isCurrent else { return }
        if !wasOpen {
            completeOpening(with: .failure(SocketError.closed))
        }
        notifyClose(nil)
    }

    func urlSession(
        _ session: URLSession,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        lifecycleLock.lock()
        let isCurrent = urlSession === session
        let wasOpen = didOpen
        lifecycleLock.unlock()
        guard isCurrent else { return }
        if !wasOpen {
            completeOpening(with: .failure(error))
        }
        notifyClose(error)
    }
}
