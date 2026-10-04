import AppKit

@MainActor
final class MainViewController: NSViewController {
    private let configuration: ConsoleConfiguration
    private let credentialStore: SecureCredentialStore
    private let statusWriter: ConsoleStatusWriter
    private let capture: USBScreenCapture
    private let inputClient: RFBInputClient
    private lazy var microphoneCoordinator = MicrophoneInputCoordinator(inputClient: inputClient)
    private lazy var nativeMicrophone = NativeMicrophoneCapture(coordinator: microphoneCoordinator)
    private lazy var webServer = WebConsoleServer(
        capture: capture,
        inputClient: inputClient,
        microphoneCoordinator: microphoneCoordinator,
        encoderConfiguration: configuration.encoder,
        audioBitRate: configuration.audioBitRate
    )

    private let previewView = LowLatencyVideoPreviewView(frame: .zero)
    private let interactionView = InteractionOverlayView(frame: .zero)
    private let previewContainer = NSView(frame: .zero)

    private let captureStatusLabel = NSTextField(labelWithString: "画面：正在初始化…")
    private let fpsLabel = NSTextField(labelWithString: "-- fps")
    private let controlStatusLabel = NSTextField(labelWithString: "控制：未连接")
    private let passwordField = NSSecureTextField(frame: .zero)
    private let connectButton = NSButton(title: "连接控制", target: nil, action: nil)
    private let retryCaptureButton = NSButton(title: "重新查找画面", target: nil, action: nil)
    private let pairCaptureButton = NSButton(title: "绑定当前 USB 画面", target: nil, action: nil)
    private let captureCandidatePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let homeButton = NSButton(title: "主屏幕", target: nil, action: nil)
    private let lockButton = NSButton(title: "锁屏 / 唤醒", target: nil, action: nil)
    private let soundToggleButton = NSButton(checkboxWithTitle: "播放手机声音", target: nil, action: nil)
    private let pushToTalkButton = PushToTalkButton(title: "按住说话", target: nil, action: nil)
    private let microphoneStatusLabel = NSTextField(labelWithString: "麦克风输入：待机")
    private let keyboardHintLabel = NSTextField(
        wrappingLabelWithString: "点击画面后可直接拖动和输入；右键返回主屏幕，中键触发电源键。"
    )
    private let webStatusLabel = NSTextField(labelWithString: "本机桥接：未启动")

    private var captureState: USBScreenCapture.State = .idle
    private var captureAudioAvailability: USBScreenCapture.AudioAvailability = .unavailable
    private var serverInfo: RFBInputClient.ServerInfo?
    private var isConnectingControl = false
    private var nativeMicrophoneState: NativeMicrophoneCapture.State = .idle
    private var activeMicrophoneStream: MicrophoneInputCoordinator.ActiveStream?
    private var appResignObserver: NSObjectProtocol?
    private var statusHeartbeatTimer: Timer?
    private var controlReconnectWorkItem: DispatchWorkItem?
    private var bridgeRestartWorkItem: DispatchWorkItem?
    private var controlReconnectAttempt = 0
    private var bridgeRestartAttempt = 0
    private var automaticControlEnabled = false
    private var isShuttingDown = false

    init(configuration: ConsoleConfiguration = .load()) {
        self.configuration = configuration
        let credentialStore = SecureCredentialStore(tokenFileURL: configuration.bridgeTokenFileURL)
        self.credentialStore = credentialStore
        let pairedCaptureID = configuration.captureDeviceUniqueID ??
            (try? credentialStore.loadCaptureDeviceUniqueID())
        capture = USBScreenCapture(
            targetUDID: configuration.targetUDID,
            expectedCaptureDeviceUniqueID: pairedCaptureID,
            targetFrameRate: Double(configuration.encoder.expectedFrameRate)
        )
        inputClient = RFBInputClient(targetUDID: configuration.targetUDID)
        statusWriter = ConsoleStatusWriter(
            fileURL: configuration.statusFileURL,
            deviceID: configuration.deviceID,
            displayName: configuration.displayName
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 900))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        configureCallbacks()
        capture.start()
        startStatusHeartbeat()
        ensureBridgeStarted()
        enableAutomaticControlIfConfigured()
    }

    func shutdown() {
        isShuttingDown = true
        controlReconnectWorkItem?.cancel()
        bridgeRestartWorkItem?.cancel()
        statusHeartbeatTimer?.invalidate()
        statusHeartbeatTimer = nil
        nativeMicrophone.shutdown()
        microphoneCoordinator.stopAll()
        interactionView.controlEnabled = false
        inputClient.releaseAllInputs()
        inputClient.disconnect()
        webServer.stop()
        previewView.capture = nil
        capture.stop()
        statusWriter.updateCapture(running: false, frameAgeMilliseconds: nil)
        statusWriter.updateRFBConnected(false)
        statusWriter.updateWebRunning(false)
        statusWriter.updateAudioRunning(false)
        statusWriter.updateMicrophoneBridgeState("unavailable")
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
    }

    private func configureViews() {
        let titleLabel = NSTextField(labelWithString: configuration.displayName)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)

        let subtitleLabel = NSTextField(
            wrappingLabelWithString: "USB 系统视频与声音负责播放，TrollVNC 连接发送控制和按住说话输入。"
        )
        subtitleLabel.textColor = .secondaryLabelColor

        captureStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        fpsLabel.alignment = .right
        controlStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)

        passwordField.placeholderString = "VNC 密码（最多 8 个 ASCII 字符）"
        passwordField.maximumNumberOfLines = 1
        passwordField.target = self
        passwordField.action = #selector(connectButtonPressed(_:))

        connectButton.target = self
        connectButton.action = #selector(connectButtonPressed(_:))
        connectButton.keyEquivalent = "\r"

        retryCaptureButton.target = self
        retryCaptureButton.action = #selector(retryCapturePressed(_:))
        pairCaptureButton.target = self
        pairCaptureButton.action = #selector(pairCapturePressed(_:))
        pairCaptureButton.isHidden = true
        captureCandidatePopup.isHidden = true
        captureCandidatePopup.setContentHuggingPriority(.required, for: .horizontal)

        homeButton.target = self
        homeButton.action = #selector(homePressed(_:))
        lockButton.target = self
        lockButton.action = #selector(lockPressed(_:))

        soundToggleButton.state = .on
        soundToggleButton.target = self
        soundToggleButton.action = #selector(soundTogglePressed(_:))
        microphoneStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        microphoneStatusLabel.textColor = .secondaryLabelColor
        pushToTalkButton.onPressChanged = { [weak self] pressed in
            guard let self else { return }
            if pressed {
                nativeMicrophone.start()
            } else {
                nativeMicrophone.stop()
            }
        }

        keyboardHintLabel.textColor = .secondaryLabelColor
        keyboardHintLabel.font = .systemFont(ofSize: 11)

        webStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)

        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.black.cgColor
        previewContainer.layer?.cornerRadius = 12
        previewContainer.layer?.masksToBounds = true

        previewView.capture = capture
        previewView.videoGravity = .resizeAspect
        interactionView.delegate = self
        interactionView.controlEnabled = false

        previewContainer.addSubview(previewView)
        previewContainer.addSubview(interactionView)
        previewView.translatesAutoresizingMaskIntoConstraints = false
        interactionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            interactionView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            interactionView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            interactionView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            interactionView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor)
        ])

        let headingStack = NSStackView(views: [titleLabel, subtitleLabel])
        headingStack.orientation = .vertical
        headingStack.alignment = .leading
        headingStack.spacing = 4

        let captureRow = NSStackView(views: [
            captureStatusLabel,
            fpsLabel,
            captureCandidatePopup,
            pairCaptureButton,
            retryCaptureButton
        ])
        captureRow.orientation = .horizontal
        captureRow.alignment = .centerY
        captureRow.spacing = 10
        captureStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fpsLabel.setContentHuggingPriority(.required, for: .horizontal)
        retryCaptureButton.setContentHuggingPriority(.required, for: .horizontal)
        pairCaptureButton.setContentHuggingPriority(.required, for: .horizontal)

        let passwordRow = NSStackView(views: [passwordField, connectButton])
        passwordRow.orientation = .horizontal
        passwordRow.alignment = .centerY
        passwordRow.spacing = 8
        passwordField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        connectButton.setContentHuggingPriority(.required, for: .horizontal)

        let actionRow = NSStackView(views: [homeButton, lockButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.distribution = .fillEqually
        actionRow.spacing = 8

        let audioRow = NSStackView(views: [soundToggleButton, pushToTalkButton])
        audioRow.orientation = .horizontal
        audioRow.alignment = .centerY
        audioRow.distribution = .fillEqually
        audioRow.spacing = 8

        let controlPanel = NSStackView(views: [
            controlStatusLabel,
            passwordRow,
            actionRow,
            microphoneStatusLabel,
            audioRow,
            keyboardHintLabel
        ])
        controlPanel.orientation = .vertical
        controlPanel.alignment = .leading
        controlPanel.spacing = 8
        passwordRow.widthAnchor.constraint(equalTo: controlPanel.widthAnchor).isActive = true
        actionRow.widthAnchor.constraint(equalTo: controlPanel.widthAnchor).isActive = true
        audioRow.widthAnchor.constraint(equalTo: controlPanel.widthAnchor).isActive = true
        keyboardHintLabel.widthAnchor.constraint(equalTo: controlPanel.widthAnchor).isActive = true

        let webPanel = NSStackView(views: [webStatusLabel])
        webPanel.orientation = .vertical
        webPanel.alignment = .leading
        webPanel.spacing = 8

        let rootStack = NSStackView(views: [headingStack, captureRow, previewContainer, controlPanel, webPanel])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        headingStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        captureRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        previewContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        controlPanel.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        webPanel.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 420)
        ])

        updateControlAvailability()
    }

    private func configureCallbacks() {
        previewView.onVideoRectChange = { [weak self] rect in
            self?.interactionView.videoRect = rect
        }

        capture.onStateChange = { [weak self] state in
            guard let self else { return }
            let previousState = self.captureState
            self.captureState = state
            if state != previousState,
               state != .running || previousState != .running {
                // Drop decoder/display queue state across every capture graph
                // transition. The current image is preserved during recovery.
                self.previewView.flush(removeDisplayedImage: false)
            }
            self.captureStatusLabel.stringValue = self.captureStatusText(for: state)
            if state != .running {
                self.fpsLabel.stringValue = "-- fps"
            }
            self.updateCapturePairingAvailability()
            self.statusWriter.updateCapture(
                running: state == .running,
                frameAgeMilliseconds: state == .running
                    ? self.capture.frameAgeMetrics.averageMilliseconds
                    : nil
            )
            if state == .running {
                self.statusWriter.updateError(nil)
            } else if let error = self.capture.lastError {
                self.statusWriter.updateError(self.captureErrorCode(error))
            }
            self.updateControlAvailability()
            self.publishWebCaptureStatus()
        }

        capture.onFPSChange = { [weak self] fps in
            guard let self else { return }
            self.updateCaptureMetricsLabel()
            self.statusWriter.updateCapture(
                running: self.captureState == .running,
                frameAgeMilliseconds: self.capture.frameAgeMetrics.averageMilliseconds
            )
            self.updateControlAvailability()
            self.publishWebCaptureStatus()
        }

        capture.onFrameAgeChange = { [weak self] metrics in
            guard let self else { return }
            updateCaptureMetricsLabel()
            statusWriter.updateCapture(
                running: captureState == .running,
                frameAgeMilliseconds: metrics.averageMilliseconds
            )
            publishWebCaptureStatus()
        }

        capture.onTargetUSBConnectionChange = { [weak self] connected in
            self?.statusWriter.updateUSBConnected(connected)
        }

        capture.onCaptureCandidatesChange = { [weak self] candidates in
            guard let self else { return }
            captureCandidatePopup.removeAllItems()
            for candidate in candidates {
                captureCandidatePopup.addItem(withTitle: candidate.displayLabel)
                captureCandidatePopup.lastItem?.representedObject = candidate.fingerprint
            }
            updateCapturePairingAvailability()
        }

        capture.onAudioAvailabilityChange = { [weak self] availability in
            guard let self else { return }
            captureAudioAvailability = availability
            captureStatusLabel.stringValue = captureStatusText(for: captureState)
            applyAudioPreviewVolume()
            statusWriter.updateAudioRunning(availability == .available)
            updateControlAvailability()
        }

        inputClient.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .disconnected:
                self.pushToTalkButton.cancelPress(reason: .controlDisconnected)
                self.nativeMicrophone.stop()
                self.microphoneCoordinator.stopAll()
                self.serverInfo = nil
                self.isConnectingControl = false
                self.controlStatusLabel.stringValue = "控制：未连接"
                self.statusWriter.updateRFBConnected(false)
                self.statusWriter.updateMicrophoneBridgeState("unavailable")
                self.scheduleControlReconnect()
            case .connecting:
                self.serverInfo = nil
                self.isConnectingControl = true
                self.controlStatusLabel.stringValue = "控制：正在通过 USB 认证…"
                self.statusWriter.updateRFBConnected(false)
                self.statusWriter.updateMicrophoneBridgeState("idle")
            case .connected(let info):
                self.serverInfo = info
                self.isConnectingControl = false
                self.interactionView.framebufferSize = CGSize(
                    width: Int(info.framebufferWidth),
                    height: Int(info.framebufferHeight)
                )
                self.controlStatusLabel.stringValue = "控制：已连接（仅输入）"
                self.controlReconnectAttempt = 0
                self.statusWriter.updateRFBConnected(true)
                self.statusWriter.updateMicrophoneBridgeState("ready")
                self.statusWriter.updateError(nil)
            }
            self.webServer.updateControlStatus(
                state: self.webControlStateText(for: state),
                connected: self.inputClient.isConnected,
                serverInfo: self.serverInfo
            )
            self.updateControlAvailability()
        }

        inputClient.onError = { [weak self] error in
            guard let self else { return }
            self.pushToTalkButton.cancelPress(reason: .controlError)
            self.nativeMicrophone.stop()
            self.microphoneCoordinator.stopAll()
            self.controlStatusLabel.stringValue = "控制：\(error.localizedDescription)"
            self.statusWriter.updateRFBConnected(false)
            self.statusWriter.updateMicrophoneBridgeState("unavailable")
            self.statusWriter.updateError("rfb_\(String(describing: error))")
            self.webServer.updateControlStatus(
                state: "disconnected",
                connected: false,
                serverInfo: nil
            )
            self.updateControlAvailability()
            self.scheduleControlReconnect()
        }

        webServer.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .stopped:
                self.webStatusLabel.stringValue = "本机桥接：未启动"
                self.statusWriter.updateWebRunning(false)
                self.scheduleBridgeRestart()
            case .starting:
                self.webStatusLabel.stringValue = "本机桥接：正在启动…"
                self.statusWriter.updateWebRunning(false)
            case .running:
                self.webStatusLabel.stringValue = "本机桥接：已就绪"
                self.bridgeRestartAttempt = 0
                self.statusWriter.updateWebRunning(true)
            case .stopping:
                self.webStatusLabel.stringValue = "本机桥接：正在停止…"
                self.statusWriter.updateWebRunning(false)
            case .failed(let message):
                self.webStatusLabel.stringValue = "本机桥接：暂时不可用"
                self.statusWriter.updateWebRunning(false)
                self.statusWriter.updateError("bridge_\(message)")
                self.scheduleBridgeRestart()
            }
        }

        nativeMicrophone.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                nativeMicrophoneState = state
                applyAudioPreviewVolume()
                updateMicrophoneUI()
                updateMicrophoneBridgeStatus()
            }
        }

        microphoneCoordinator.onStateChange = { [weak self] stream in
            Task { @MainActor [weak self] in
                guard let self else { return }
                activeMicrophoneStream = stream
                applyAudioPreviewVolume()
                updateMicrophoneUI()
                updateMicrophoneBridgeStatus()
            }
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                pushToTalkButton.cancelPress(reason: .applicationResigned)
                nativeMicrophone.stop()
            }
        }

        publishWebCaptureStatus()
        webServer.updateControlStatus(state: "disconnected", connected: false, serverInfo: nil)
        statusWriter.updateUSBConnected(capture.targetUSBConnected)
        statusWriter.updateMicrophoneBridgeState("idle")
    }

    private func captureStatusText(for state: USBScreenCapture.State) -> String {
        switch state {
        case .idle:
            return "画面：未启动"
        case .requestingAuthorization:
            if captureAudioAvailability == .requestingAuthorization {
                return "画面：等待 macOS 音频采集权限"
            }
            return "画面：等待相机权限"
        case .searching:
            return "画面：正在查找 USB iPhone"
        case .configuring:
            return "画面：正在建立系统视频流"
        case .running:
            return "画面：USB 视频已连接 · \(phoneAudioStatusText)"
        case .waitingForDevice:
            switch capture.lastError {
            case .some(.deviceInUse):
                return "画面：iPhone 视频正被其他应用占用"
            case .some(.targetUSBDeviceNotConnected):
                return "画面：等待指定的 USB iPhone"
            case .some(.captureDevicePairingRequired):
                return "画面：需要绑定指定的 USB 画面"
            case .some(.configuredCaptureDeviceUnavailable):
                return "画面：已绑定的 USB 画面不可用"
            case .some(.captureDevicePairingAmbiguous):
                return "画面：请仅保留要绑定的 iPhone"
            default:
                break
            }
            return "画面：等待 USB iPhone"
        case .interrupted:
            return "画面：视频流暂时中断"
        case .recovering:
            return "画面：正在自动恢复"
        case .permissionDenied:
            return "画面：相机权限未允许"
        case .permissionRestricted:
            return "画面：相机权限受系统限制"
        case .failed:
            return "画面：系统视频初始化失败"
        }
    }

    private var phoneAudioStatusText: String {
        switch captureAudioAvailability {
        case .available:
            return "手机声音可用"
        case .requestingAuthorization:
            return "正在请求手机声音权限"
        case .permissionDenied:
            return "手机声音未获 macOS 音频采集权限"
        case .permissionRestricted:
            return "手机声音权限受系统限制"
        case .unavailable:
            return "手机声音当前不可用"
        }
    }

    private func updateCaptureMetricsLabel() {
        guard capture.fps > 0 else {
            fpsLabel.stringValue = "-- fps"
            return
        }

        if let averageAge = capture.frameAgeMetrics.averageMilliseconds,
           averageAge.isFinite {
            fpsLabel.stringValue = String(
                format: "%.1f fps · 帧龄 %.0f ms",
                capture.fps,
                averageAge
            )
        } else {
            fpsLabel.stringValue = String(format: "%.1f fps", capture.fps)
        }
    }

    private func updateControlAvailability() {
        let captureReady = captureState == .running && capture.fps > 1
        let connected = serverInfo != nil && inputClient.isConnected

        interactionView.controlEnabled = captureReady && connected
        passwordField.isEnabled = !connected && !isConnectingControl
        retryCaptureButton.isEnabled = captureState != .requestingAuthorization && captureState != .configuring

        connectButton.title = connected ? "断开控制" : (isConnectingControl ? "取消" : "连接控制")
        connectButton.isEnabled = connected || isConnectingControl || captureReady
        homeButton.isEnabled = captureReady && connected
        lockButton.isEnabled = captureReady && connected
        soundToggleButton.isEnabled = captureReady && captureAudioAvailability == .available
        // Microphone injection uses the authenticated RFB/USB path and must not
        // be interrupted by transient video-capture FPS changes.
        pushToTalkButton.isEnabled = connected && {
            guard let stream = activeMicrophoneStream else { return true }
            return stream.owner.hasPrefix("native:")
        }()
        updateMicrophoneUI()
        updateCapturePairingAvailability()
    }

    private func updateMicrophoneUI() {
        if let stream = activeMicrophoneStream, stream.owner.hasPrefix("web:") {
            microphoneStatusLabel.stringValue = "麦克风输入：网页正在说话"
            return
        }
        switch nativeMicrophoneState {
        case .idle:
            microphoneStatusLabel.stringValue = "麦克风输入：按住按钮说话"
        case .requestingPermission:
            microphoneStatusLabel.stringValue = "麦克风输入：等待 macOS 权限"
        case .starting:
            microphoneStatusLabel.stringValue = "麦克风输入：正在开始"
        case .running:
            microphoneStatusLabel.stringValue = "麦克风输入：正在发送"
        case .busy:
            microphoneStatusLabel.stringValue = "麦克风输入：正在被另一控制端使用"
        case .permissionDenied:
            microphoneStatusLabel.stringValue = "麦克风输入：macOS 麦克风权限未允许"
        case .failed:
            microphoneStatusLabel.stringValue = "麦克风输入：手机音频桥未就绪"
        }
    }

    private func applyAudioPreviewVolume() {
        guard soundToggleButton.state == .on, captureAudioAvailability == .available else {
            capture.setAudioPreviewVolume(0)
            return
        }
        if let stream = activeMicrophoneStream {
            // A native microphone has no acoustic echo-cancellation reference
            // for AVCaptureAudioPreviewOutput, so local PTT must hard-mute it.
            capture.setAudioPreviewVolume(stream.owner.hasPrefix("native:") ? 0 : 0.2)
        } else {
            capture.setAudioPreviewVolume(1)
        }
    }

    private func publishWebCaptureStatus() {
        let connected = captureState == .running && capture.fps > 1
        let state: String
        switch captureState {
        case .running:
            state = connected ? "connected" : "connecting"
        case .requestingAuthorization, .searching, .configuring, .recovering:
            state = "connecting"
        default:
            state = "disconnected"
        }
        webServer.updateCaptureStatus(
            state: state,
            connected: connected,
            fps: capture.fps > 0 ? capture.fps : nil,
            frameAgeMilliseconds: capture.frameAgeMetrics.averageMilliseconds,
            deviceName: capture.deviceName
        )
    }

    private func webControlStateText(for state: RFBInputClient.State) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        }
    }

    private func startStatusHeartbeat() {
        statusHeartbeatTimer?.invalidate()
        statusHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.statusWriter.heartbeat()
            }
        }
        statusHeartbeatTimer?.tolerance = 1
    }

    private func ensureBridgeStarted() {
        guard !isShuttingDown else { return }
        switch webServer.state {
        case .starting, .running, .stopping:
            return
        case .stopped, .failed:
            do {
                let token = try credentialStore.loadOrCreateBridgeToken()
                webServer.start(bridgeToken: token)
            } catch {
                webStatusLabel.stringValue = "本机桥接：凭据不可用"
                statusWriter.updateWebRunning(false)
                statusWriter.updateError("bridge_credentials_unavailable")
                scheduleBridgeRestart()
            }
        }
    }

    private func scheduleBridgeRestart() {
        guard !isShuttingDown, bridgeRestartWorkItem == nil else { return }
        let delay = min(1.0 * pow(2, Double(bridgeRestartAttempt)), 15)
        bridgeRestartAttempt = min(bridgeRestartAttempt + 1, 5)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            bridgeRestartWorkItem = nil
            ensureBridgeStarted()
        }
        bridgeRestartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func enableAutomaticControlIfConfigured() {
        do {
            guard try credentialStore.loadVNCPassword() != nil else { return }
            automaticControlEnabled = true
            scheduleControlReconnect(immediate: true)
        } catch {
            statusWriter.updateError("vnc_credentials_unavailable")
        }
    }

    private func scheduleControlReconnect(immediate: Bool = false) {
        guard automaticControlEnabled, !isShuttingDown,
              !inputClient.isConnected, !isConnectingControl,
              controlReconnectWorkItem == nil else { return }
        let delay = immediate ? 0 : min(0.5 * pow(2, Double(controlReconnectAttempt)), 10)
        controlReconnectAttempt = min(controlReconnectAttempt + 1, 6)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            controlReconnectWorkItem = nil
            guard automaticControlEnabled, !isShuttingDown,
                  !inputClient.isConnected, !isConnectingControl else { return }
            do {
                guard let password = try credentialStore.loadVNCPassword() else {
                    automaticControlEnabled = false
                    return
                }
                connectControl(password: password, persistOnSuccess: false)
            } catch {
                statusWriter.updateError("vnc_credentials_unavailable")
                scheduleControlReconnect()
            }
        }
        controlReconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func connectControl(password: String, persistOnSuccess: Bool) {
        guard SecureCredentialStore.isValidVNCPassword(password),
              !inputClient.isConnected, !isConnectingControl else { return }
        isConnectingControl = true
        controlStatusLabel.stringValue = "控制：正在通过 USB 认证…"
        updateControlAvailability()

        inputClient.connect(password: password) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if persistOnSuccess {
                    do {
                        try credentialStore.saveVNCPassword(password)
                        automaticControlEnabled = true
                    } catch {
                        controlStatusLabel.stringValue = "控制：已连接，但无法保存凭据"
                        statusWriter.updateError("vnc_credentials_save_failed")
                    }
                }
                passwordField.stringValue = ""
            case .failure(let error):
                if (error as? RFBInputClient.ClientError) != .cancelled {
                    controlStatusLabel.stringValue = "控制：\(error.localizedDescription)"
                }
                scheduleControlReconnect()
            }
            updateControlAvailability()
        }
    }

    private func updateCapturePairingAvailability() {
        guard let error = capture.lastError else {
            pairCaptureButton.isHidden = true
            pairCaptureButton.isEnabled = false
            captureCandidatePopup.isHidden = true
            return
        }
        switch error {
        case .captureDevicePairingRequired, .configuredCaptureDeviceUnavailable,
             .captureDevicePairingAmbiguous:
            pairCaptureButton.isHidden = false
            captureCandidatePopup.isHidden = false
            pairCaptureButton.isEnabled = captureCandidatePopup.numberOfItems > 0 &&
                captureState != .requestingAuthorization &&
                captureState != .configuring && capture.targetUSBConnected
        default:
            pairCaptureButton.isHidden = true
            pairCaptureButton.isEnabled = false
            captureCandidatePopup.isHidden = true
        }
    }

    private func captureErrorCode(_ error: USBScreenCapture.CaptureError) -> String {
        switch error {
        case .targetUSBDeviceNotConnected:
            return "capture_target_usb_missing"
        case .captureDevicePairingRequired(let fingerprints):
            return "capture_pairing_required:\(fingerprints.joined(separator: ","))"
        case .configuredCaptureDeviceUnavailable:
            return "capture_paired_device_missing"
        case .captureDevicePairingAmbiguous:
            return "capture_pairing_ambiguous"
        case .deviceInUse:
            return "capture_device_in_use"
        case .firstFrameTimedOut:
            return "capture_first_frame_timeout"
        case .streamStalled:
            return "capture_stream_stalled"
        default:
            return "capture_\(String(describing: error))"
        }
    }

    private func updateMicrophoneBridgeStatus() {
        if activeMicrophoneStream != nil || nativeMicrophoneState == .running {
            statusWriter.updateMicrophoneBridgeState("active")
        } else if inputClient.isConnected {
            switch nativeMicrophoneState {
            case .failed, .permissionDenied:
                statusWriter.updateMicrophoneBridgeState("unavailable")
            default:
                statusWriter.updateMicrophoneBridgeState("ready")
            }
        } else if isConnectingControl {
            statusWriter.updateMicrophoneBridgeState("idle")
        } else {
            statusWriter.updateMicrophoneBridgeState("unavailable")
        }
    }

    @objc private func retryCapturePressed(_ sender: Any?) {
        capture.retry()
    }

    @objc private func pairCapturePressed(_ sender: Any?) {
        guard let fingerprint = captureCandidatePopup.selectedItem?.representedObject as? String else {
            statusWriter.updateError("capture_pairing_candidate_missing")
            return
        }
        pairCaptureButton.isEnabled = false
        captureStatusLabel.stringValue = "画面：正在绑定所选 USB 画面…"
        capture.requestPairingCandidate(fingerprint: fingerprint) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let uniqueID):
                    do {
                        try credentialStore.saveCaptureDeviceUniqueID(uniqueID)
                        capture.setExpectedCaptureDeviceUniqueID(uniqueID)
                        pairCaptureButton.isHidden = true
                        statusWriter.updateError(nil)
                    } catch {
                        captureStatusLabel.stringValue = "画面：无法保存 USB 画面绑定"
                        statusWriter.updateError("capture_pairing_save_failed")
                    }
                case .failure(let error):
                    captureStatusLabel.stringValue = captureStatusText(for: captureState)
                    statusWriter.updateError(captureErrorCode(error))
                }
                updateCapturePairingAvailability()
            }
        }
    }

    @objc private func connectButtonPressed(_ sender: Any?) {
        if inputClient.isConnected || isConnectingControl {
            automaticControlEnabled = false
            controlReconnectWorkItem?.cancel()
            controlReconnectWorkItem = nil
            interactionView.controlEnabled = false
            inputClient.releaseAllInputs()
            inputClient.disconnect()
            return
        }

        let password = passwordField.stringValue
        guard SecureCredentialStore.isValidVNCPassword(password) else {
            controlStatusLabel.stringValue = "控制：请输入不超过 8 个 ASCII 字符的 VNC 密码"
            return
        }
        connectControl(password: password, persistOnSuccess: true)
    }

    @objc private func homePressed(_ sender: Any?) {
        sendButtonPulse(mask: 4)
    }

    @objc private func lockPressed(_ sender: Any?) {
        sendButtonPulse(mask: 2)
    }

    @objc private func soundTogglePressed(_ sender: Any?) {
        applyAudioPreviewVolume()
    }

    private func sendButtonPulse(mask: UInt8) {
        guard let info = serverInfo else { return }
        let x = info.framebufferWidth / 2
        let y = info.framebufferHeight / 2
        inputClient.sendPointer(mask: mask, x: x, y: y)
        inputClient.sendPointer(mask: 0, x: x, y: y)
    }
}

extension MainViewController: InteractionOverlayViewDelegate {
    func interactionOverlayView(
        _ view: InteractionOverlayView,
        sendPointerMask mask: UInt8,
        x: UInt16,
        y: UInt16
    ) {
        inputClient.sendPointer(mask: mask, x: x, y: y)
    }

    func interactionOverlayView(
        _ view: InteractionOverlayView,
        sendKeyDown down: Bool,
        keysym: UInt32
    ) {
        inputClient.sendKey(down: down, keysym: keysym)
    }

    func interactionOverlayViewDidRequestReleaseAllInputs(_ view: InteractionOverlayView) {
        inputClient.releaseAllInputs()
    }
}
