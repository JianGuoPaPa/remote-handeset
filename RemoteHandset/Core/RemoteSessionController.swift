import AVFoundation
import Foundation
import OSLog
import SwiftUI
import UIKit
import WebRTC

@MainActor
final class RemoteSessionController: ObservableObject {
    enum SessionState: Equatable {
        case signedOut
        case authenticating
        case preparing
        case signaling
        case connecting
        case connected
        case reconnecting
        case waitingForNetwork
        case failed(String)

        var label: String {
            switch self {
            case .signedOut:
                return "未连接"
            case .authenticating:
                return "正在验证"
            case .preparing:
                return "正在准备"
            case .signaling:
                return "正在协商"
            case .connecting:
                return "正在连接设备"
            case .connected:
                return "已连接"
            case .reconnecting:
                return "正在恢复连接"
            case .waitingForNetwork:
                return "等待网络"
            case let .failed(message):
                return message
            }
        }

        var isBusy: Bool {
            switch self {
            case .authenticating, .preparing, .signaling, .connecting, .reconnecting:
                return true
            default:
                return false
            }
        }
    }

    @Published private(set) var state: SessionState = .signedOut
    @Published private(set) var isAuthenticated = false
    @Published private(set) var loginMessage: String?
    @Published private(set) var loginMessageIsError = false
    @Published private(set) var videoTrack: RTCVideoTrack?
    @Published private(set) var mediaMetadata: RemoteMediaMetadata?
    @Published private(set) var capabilities: RemoteCapabilities?
    @Published private(set) var diagnostics = ConnectionDiagnostics.empty
    @Published private(set) var lastGatewayMessage: String?
    @Published private(set) var remoteClipboardText: String?
    @Published private(set) var isControlReady = false
    @Published private(set) var isMicrophoneControlReady = false
    @Published private(set) var deviceNames =
        RemoteSessionController.loadDeviceNames()
    @Published private(set) var selectedDeviceTarget =
        RemoteSessionController.loadLastConnectedDeviceTarget()
    @Published private(set) var privacyModeEnabled =
        RemoteSessionController.loadPrivacyModeEnabled()
    @Published private(set) var showsNonPrivacyModeNotice = false
    // Covers the remote screen while privacy mode is enabled and the app is
    // interrupted, so a glance away never exposes the remote screen.
    @Published private(set) var isObscured = false
    @Published private(set) var deviceConnection: DeviceConnectionStatus?
    @Published private(set) var isSwitchingDeviceConnection = false
    @Published private(set) var deviceConnectionMessage: String?
    @Published private var deviceConnectionCheckedAt: Date?

    var showsDeviceConnection: Bool {
        selectedDeviceTarget.type == .android
            && deviceConnection?.deviceID == selectedDeviceTarget.id
            && deviceConnection?.wirelessConfigured == true
    }
    var deviceConnectionIsFresh: Bool {
        guard let checkedAt = deviceConnectionCheckedAt else { return false }
        return Date().timeIntervalSince(checkedAt) < 30
    }
    var deviceConnectionIsBusy: Bool {
        isSwitchingDeviceConnection || deviceConnection?.isSwitching == true
    }
    var canSwitchToWireless: Bool {
        showsDeviceConnection && deviceConnectionIsFresh && !deviceConnectionIsBusy
            && deviceConnection?.wifiAvailable == true
            && (deviceConnection?.preference != "wifi" || deviceConnection?.activeTransport != "wifi")
    }

    var isAuthenticating: Bool { state == .authenticating }
    var isConnected: Bool { state == .connected }
    var isIPhoneTarget: Bool { selectedDeviceTarget.type == .iPhoneUSB }
    var availableDeviceTargets: [DeviceTarget] {
        AppConfiguration.deviceTargets.map { target in
            targetWithStoredName(target)
        }
    }
    private var connectionLifecycleAllowed: Bool {
        appIsActive || !privacyModeEnabled
    }
    var savedServerAddress: String {
        UserDefaults.standard.string(forKey: AppConfiguration.serverDefaultsKey)
            ?? AppConfiguration.defaultServerString
    }

    var rememberPassword: Bool {
        if UserDefaults.standard.object(forKey: AppConfiguration.rememberPasswordDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: AppConfiguration.rememberPasswordDefaultsKey)
    }

    var savedPassword: String? {
        keychain.value(account: AppConfiguration.keychainPasswordAccount)
    }

    private let keychain = KeychainStore(service: AppConfiguration.keychainService)
    private let logger = Logger(
        subsystem: "com.dltengwen.remotehandset",
        category: "Session"
    )
    private let networkMonitor = NetworkMonitor()
    private var portal: PortalAPI
    private var webRTC: WebRTCClient?
    private var signaling: SignalingSocket?
    private var deviceConnectionMonitorTask: Task<Void, Never>?
    private var deviceConnectionSwitchTask: Task<Void, Never>?
    private var deviceConnectionScope = UUID()
    private var deviceConnectionRequestSequence: UInt64 = 0
    private var deviceConnectionAcceptedSequence: UInt64 = 0
    private var sessionCSRF: String?
    private var connectionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var disconnectGraceTask: Task<Void, Never>?
    private var connectionPhaseDeadlineTask: Task<Void, Never>?
    private var connectionTotalDeadlineTask: Task<Void, Never>?
    private var rotationMetadataDeadlineTask: Task<Void, Never>?
    private var candidate: ConnectionCandidate?
    private var pendingAdaptiveReconnect: ConnectionCandidateRequest?
    private var connectionGeneration = UUID()
    private var appIsActive = true
    private var wasAwayFromForeground = false
    private var needsForegroundReconnect = false
    private var networkIsSatisfied = true
    private var hasBootstrapped = false
    private var lastStatsSample: StatsSample?
    private var dataChannelsReady = false
    private var firstFramesReady = false
    private var peerConnected = false
    private var signalingIsOpen = false
    private var remoteAnswerApplied = false
    private var connectionPhase: ConnectionPhase?
    private var isAwaitingRotationDimensions = false
    private var rotationBaselineSize: CGSize?
    private var clipboardSequence: UInt64 = 0
    private var controlSequence: UInt64 = 0
    private var controlProtocolVersion: Int?
    private var didFallbackToLegacyControl = false
    private var controlDriverFailures: [ControlDriverFailure] = []
    private var lastControlAcknowledgementSequence: UInt64 = 0
    private var lastFrameFeedbackSequence: UInt64 = 0
    private var pendingDecodedFrameFeedback: PendingDecodedFrameFeedback?
    private var activePointers = Set<UInt8>()
    private var iPhonePrimaryPointerID: UInt8?
    private var microphoneDemand: MicrophoneDemandCursor?
    private var microphoneActivationGeneration: UInt64?
    private var microphoneActivationToken: UUID?
    private var microphoneActivationTask: Task<Void, Never>?
    private var microphoneAcknowledgementTask: Task<Void, Never>?
    private var microphoneAcknowledgedGeneration: UInt64?
    private var microphoneRetryTask: Task<Void, Never>?
    private var microphoneRetryToken: UUID?
    private var microphoneRetryAttempt = 0
    private var microphonePermissionDeniedGeneration: UInt64?
    private var reconnectAttempt = 0
    private var activeProfile: RemoteStreamProfile = AppConfiguration.defaultStreamProfile
    private var activeIceMode: RemoteIceMode = .relay
    private var adaptivePolicy = AdaptiveConnectionPolicy()

    private static let microphoneRetryDelays: [Duration] = [
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
        .seconds(4)
    ]

    init() {
        let stored = UserDefaults.standard.string(forKey: AppConfiguration.serverDefaultsKey)
        let url = Self.normalizedServerURL(from: stored ?? AppConfiguration.defaultServerString)
            ?? AppConfiguration.defaultServerURL
        portal = PortalAPI(baseURL: url)

        networkMonitor.onChange = { [weak self] snapshot, previous in
            self?.handleNetworkChange(snapshot, previous: previous)
        }
        networkMonitor.start()
    }

    deinit {
        networkMonitor.stop()
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        // A server cookie is never an unlock credential. Every cold launch
        // starts behind the local calculator gate, even if the previous portal
        // session has not expired yet.
        await portal.discardLocalSession()
        isAuthenticated = false
        sessionCSRF = nil
        state = .signedOut
        loginMessage = nil
    }

    @discardableResult
    func login(
        serverAddress: String,
        password: String,
        rememberPassword: Bool
    ) async -> Bool {
        guard !isAuthenticating else { return false }
        guard let serverURL = Self.normalizedServerURL(from: serverAddress) else {
            loginMessage = PortalError.invalidServerAddress.localizedDescription
            loginMessageIsError = true
            return false
        }

        state = .authenticating
        loginMessage = nil
        loginMessageIsError = false

        do {
            await portal.updateBaseURL(serverURL)
            let response = try await portal.login(password: password)
            guard response.authenticated else {
                throw PortalError.unauthorized
            }

            UserDefaults.standard.set(
                serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                forKey: AppConfiguration.serverDefaultsKey
            )
            UserDefaults.standard.set(
                rememberPassword,
                forKey: AppConfiguration.rememberPasswordDefaultsKey
            )

            if rememberPassword {
                do {
                    try keychain.set(
                        password,
                        account: AppConfiguration.keychainPasswordAccount
                    )
                } catch {
                    logger.error(
                        "Password persistence failed: \(String(describing: error), privacy: .public)"
                    )
                }
            } else {
                keychain.remove(account: AppConfiguration.keychainPasswordAccount)
            }

            sessionCSRF = response.csrf
            isAuthenticated = true
            loginMessage = nil
            startConnection(reconnecting: false)
            return true
        } catch {
            state = .signedOut
            isAuthenticated = false
            loginMessage = userFacingMessage(for: error)
            loginMessageIsError = true
            return false
        }
    }

    func unlockFromCalculator(_ candidate: String) async -> Bool {
        // The calculator has one unlock password. The selected target is loaded
        // from the last device that connected successfully.
        guard candidate == AppConfiguration.calculatorPassword else {
            loginMessage = nil
            loginMessageIsError = false
            return false
        }

        let target = Self.loadLastConnectedDeviceTarget()
        selectedDeviceTarget = target
        UserDefaults.standard.set(target.id, forKey: Self.selectedDeviceDefaultsKey)

        let didAuthenticate = await login(
            serverAddress: AppConfiguration.defaultServerString,
            password: AppConfiguration.portalPassword,
            rememberPassword: false
        )

        // The calculator surface deliberately exposes no authentication state.
        loginMessage = nil
        loginMessageIsError = false
        return didAuthenticate
    }

    func switchDevice(to target: DeviceTarget) {
        guard let configuredTarget = AppConfiguration.deviceTarget(id: target.id) else {
            return
        }
        let namedTarget = targetWithStoredName(configuredTarget)
        guard namedTarget != selectedDeviceTarget else { return }

        resetDeviceConnection()
        selectedDeviceTarget = namedTarget
        UserDefaults.standard.set(namedTarget.id, forKey: Self.selectedDeviceDefaultsKey)

        guard isAuthenticated, appIsActive else { return }
        reconnectAttempt = 0
        startConnection(reconnecting: true)
    }

    func renameDevice(_ target: DeviceTarget, to name: String) {
        guard let configuredTarget = AppConfiguration.deviceTarget(id: target.id) else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let normalizedName = String(trimmedName.prefix(40))

        var updatedNames = deviceNames
        if normalizedName == configuredTarget.displayName {
            updatedNames.removeValue(forKey: configuredTarget.id)
        } else {
            updatedNames[configuredTarget.id] = normalizedName
        }
        deviceNames = updatedNames
        UserDefaults.standard.set(updatedNames, forKey: Self.deviceNamesDefaultsKey)

        if selectedDeviceTarget.id == configuredTarget.id {
            selectedDeviceTarget = DeviceTarget(
                id: configuredTarget.id,
                type: configuredTarget.type,
                displayName: normalizedName
            )
        }
    }

    func setPrivacyModeEnabled(_ enabled: Bool) {
        guard privacyModeEnabled != enabled else { return }
        privacyModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.privacyModeDefaultsKey)

        if enabled {
            showsNonPrivacyModeNotice = false
        }
        if enabled, !appIsActive, isAuthenticated {
            stopAutomaticMicrophoneInput(clearDemand: true, state: "已暂停")
            lockForPrivacy()
        }
    }

    func dismissNonPrivacyModeNotice() {
        showsNonPrivacyModeNotice = false
    }

    private static let selectedDeviceDefaultsKey = "remote.selectedDeviceID"
    private static let lastConnectedDeviceDefaultsKey = "remote.lastConnectedDeviceID"
    private static let deviceNamesDefaultsKey = "remote.deviceDisplayNames"
    private static let privacyModeDefaultsKey = "remote.privacyModeEnabled"

    private static func loadDeviceNames() -> [String: String] {
        guard let stored = UserDefaults.standard.dictionary(
            forKey: deviceNamesDefaultsKey
        ) else {
            return [:]
        }

        return stored.reduce(into: [String: String]()) { result, entry in
            guard AppConfiguration.deviceTarget(id: entry.key) != nil,
                  let value = entry.value as? String
            else {
                return
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            result[entry.key] = String(trimmed.prefix(40))
        }
    }

    private func targetWithStoredName(_ target: DeviceTarget) -> DeviceTarget {
        guard let name = deviceNames[target.id], !name.isEmpty else {
            return target
        }
        return DeviceTarget(
            id: target.id,
            type: target.type,
            displayName: name
        )
    }

    private static func loadLastConnectedDeviceTarget() -> DeviceTarget {
        let stored = UserDefaults.standard.string(forKey: lastConnectedDeviceDefaultsKey)
            ?? UserDefaults.standard.string(forKey: selectedDeviceDefaultsKey)
        if let stored, let target = AppConfiguration.deviceTarget(id: stored) {
            let names = loadDeviceNames()
            return DeviceTarget(
                id: target.id,
                type: target.type,
                displayName: names[target.id] ?? target.displayName
            )
        }
        return AppConfiguration.defaultDeviceTarget
    }

    private static func loadPrivacyModeEnabled() -> Bool {
        guard let stored = UserDefaults.standard.object(forKey: privacyModeDefaultsKey) as? Bool else {
            return true
        }
        return stored
    }

    func lockForPrivacy() {
        stopConnection()
        adaptivePolicy.resetSession()
        activeProfile = AppConfiguration.defaultStreamProfile
        activeIceMode = .relay
        isAuthenticated = false
        isObscured = false
        state = .signedOut
        sessionCSRF = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func logout() {
        let csrf = sessionCSRF
        stopConnection()
        adaptivePolicy.resetSession()
        activeProfile = AppConfiguration.defaultStreamProfile
        activeIceMode = .relay
        isAuthenticated = false
        state = .signedOut
        sessionCSRF = nil
        UIApplication.shared.isIdleTimerDisabled = false
        Task {
            await portal.logout(csrf: csrf)
        }
    }

    func reconnect() {
        guard isAuthenticated, appIsActive else { return }
        startConnection(reconnecting: true)
    }

    private func resetDeviceConnection() {
        deviceConnectionScope = UUID()
        deviceConnectionMonitorTask?.cancel()
        deviceConnectionMonitorTask = nil
        deviceConnectionSwitchTask?.cancel()
        deviceConnectionSwitchTask = nil
        deviceConnection = nil
        deviceConnectionCheckedAt = nil
        deviceConnectionMessage = nil
        isSwitchingDeviceConnection = false
        deviceConnectionRequestSequence = 0
        deviceConnectionAcceptedSequence = 0
    }

    @discardableResult
    private func acceptDeviceConnection(_ value: DeviceConnectionStatus, requestSequence: UInt64) -> Bool {
        guard value.deviceID == selectedDeviceTarget.id,
              value.canReplace(deviceConnection, requestSequence: requestSequence,
                               lastAcceptedRequestSequence: deviceConnectionAcceptedSequence)
        else { return false }
        deviceConnection = value
        deviceConnectionAcceptedSequence = max(deviceConnectionAcceptedSequence, requestSequence)
        deviceConnectionCheckedAt = Date()
        return true
    }

    private func startDeviceConnectionMonitor() {
        guard selectedDeviceTarget.type == .android,
              deviceConnectionMonitorTask == nil else { return }
        let scope = deviceConnectionScope
        let deviceID = selectedDeviceTarget.id
        deviceConnectionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, scope == self.deviceConnectionScope,
                      self.isAuthenticated else { return }
                if self.networkIsSatisfied && !self.isSwitchingDeviceConnection {
                    do {
                        self.deviceConnectionRequestSequence &+= 1
                        let requestSequence = self.deviceConnectionRequestSequence
                        let response = try await self.portal.deviceConnection(deviceID: deviceID)
                        try Task.checkCancellation()
                        guard scope == self.deviceConnectionScope else { return }
                        if response.status == "ok", let value = response.connection {
                            let wasSwitching = self.deviceConnection?.isSwitching == true
                            if self.acceptDeviceConnection(value, requestSequence: requestSequence),
                               wasSwitching, !value.isSwitching {
                                self.startConnection(reconnecting: true)
                            }
                        } else {
                            self.deviceConnectionCheckedAt = nil
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        guard scope == self.deviceConnectionScope else { return }
                        // An old gateway has no management RPC. Keep the entry
                        // hidden unless this device's capability was confirmed.
                        self.deviceConnectionCheckedAt = nil
                    }
                }
                let delay: Duration = self.deviceConnection?.isSwitching == true
                    ? .seconds(2) : .seconds(15)
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    func switchDeviceConnection(to preference: String) {
        guard isAuthenticated, appIsActive, showsDeviceConnection,
              deviceConnectionIsFresh, !deviceConnectionIsBusy,
              let current = deviceConnection,
              preference == "auto" || preference == "wifi",
              preference != "wifi" || current.wifiAvailable else { return }
        let scope = deviceConnectionScope
        let deviceID = selectedDeviceTarget.id
        isSwitchingDeviceConnection = true
        deviceConnectionMessage = nil
        discardCandidate(markFailure: false)
        refreshControlReadiness()
        deviceConnectionSwitchTask = Task { [weak self] in
            guard let self else { return }
            var shouldReconnect = false
            defer {
                if scope == self.deviceConnectionScope {
                    self.isSwitchingDeviceConnection = false
                    self.deviceConnectionSwitchTask = nil
                    self.refreshControlReadiness()
                    // A peer failure can arrive while automatic reconnects are
                    // paused for the switch. Recover even when the RPC rejects
                    // the request or its acknowledgement is lost.
                    let mediaIsHealthy = self.peerConnected && self.signalingIsOpen
                        && self.dataChannelsReady && self.firstFramesReady
                    if !self.deviceConnectionIsBusy && (shouldReconnect || !mediaIsHealthy) {
                        self.startConnection(reconnecting: true)
                    }
                }
            }
            do {
                // Never retry a switch command after an uncertain network error.
                // Subsequent requests only observe its outcome.
                self.deviceConnectionRequestSequence &+= 1
                let requestSequence = self.deviceConnectionRequestSequence
                let response = try await self.portal.deviceConnection(
                    deviceID: deviceID,
                    preference: preference,
                    expectedGeneration: current.generation,
                    expectedInstanceID: current.instanceID
                )
                try Task.checkCancellation()
                guard scope == self.deviceConnectionScope else { return }
                if let value = response.connection {
                    self.acceptDeviceConnection(value, requestSequence: requestSequence)
                }
                guard response.status == "ok", let accepted = response.connection else {
                    self.deviceConnectionMessage = "切换未完成，请检查连接状态后重试"
                    self.lastGatewayMessage = response.message
                    return
                }
                self.cancelConnectionDeadlines()
                self.reconnectTask?.cancel()
                self.reconnectTask = nil
                let deadline = Date().addingTimeInterval(90)
                var result = accepted
                while result.isSwitching, Date() < deadline {
                    try await Task.sleep(for: .seconds(2))
                    do {
                        self.deviceConnectionRequestSequence &+= 1
                        let requestSequence = self.deviceConnectionRequestSequence
                        let update = try await self.portal.deviceConnection(deviceID: deviceID)
                        try Task.checkCancellation()
                        guard scope == self.deviceConnectionScope else { return }
                        if update.status == "ok", let value = update.connection,
                           (value.instanceID != accepted.instanceID || value.generation >= accepted.generation),
                           self.acceptDeviceConnection(value, requestSequence: requestSequence) {
                            result = value
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        guard scope == self.deviceConnectionScope else { return }
                        self.deviceConnectionCheckedAt = nil
                    }
                }
                guard scope == self.deviceConnectionScope else { return }
                if result.isSwitching {
                    self.deviceConnectionMessage = "仍在确认连接方式，状态将自动更新"
                } else if result.state == "failed" {
                    self.deviceConnectionMessage = result.lastError == "switch_failed_previous_connection_restored"
                        ? "切换失败，已恢复原连接" : "切换未完成，请检查当前连接后重试"
                    self.lastGatewayMessage = result.lastError
                } else if preference == "wifi", result.activeTransport == "wifi" {
                    self.deviceConnectionMessage = "无线连接已就绪"
                } else if preference == "auto" {
                    self.deviceConnectionMessage = "已恢复自动连接（有线优先）"
                } else {
                    self.deviceConnectionMessage = "无线暂不可用，当前使用有线连接"
                }
                shouldReconnect = !result.isSwitching
            } catch is CancellationError {
                return
            } catch {
                guard scope == self.deviceConnectionScope else { return }
                self.deviceConnectionCheckedAt = nil
                self.deviceConnectionMessage = "暂时无法确认切换结果，正在重新检查"
                shouldReconnect = true
            }
        }
    }

    func sendTouch(
        action: RemoteTouchAction,
        pointerID: UInt8,
        x: UInt16,
        y: UInt16,
        pressure: UInt16,
        buttons: UInt8
    ) {
        guard isControlReady else { return }

        if isIPhoneTarget {
            switch action {
            case .down:
                guard iPhonePrimaryPointerID == nil else { return }
            case .move, .up:
                guard iPhonePrimaryPointerID == pointerID else { return }
            }
        }

        let result = sendControl(
            ControlPacket.touch(
                action: action,
                pointerID: pointerID,
                x: x,
                y: y,
                pressure: pressure,
                buttons: buttons
            ),
            transport: action == .move ? .transient : .ordered
        )

        if action == .down, result == .sent {
            activePointers.insert(pointerID)
            if isIPhoneTarget {
                iPhonePrimaryPointerID = pointerID
            }
        } else if action == .up, result == .sent {
            activePointers.remove(pointerID)
            if iPhonePrimaryPointerID == pointerID {
                iPhonePrimaryPointerID = nil
            }
        }

        if action == .up,
           result == .sent,
           activePointers.isEmpty {
            resumeDeferredConnectionChangeIfPossible()
        }
    }

    private func resumeDeferredConnectionChangeIfPossible() {
        guard activePointers.isEmpty, !hasActiveMicrophoneDemand else { return }
        if let pending = pendingAdaptiveReconnect {
            pendingAdaptiveReconnect = nil
            handleAdaptiveConnectionRequest(
                pending,
                generation: connectionGeneration
            )
        } else if candidate?.readyForPromotion == true {
            promoteCandidate()
        }
    }

    func sendKey(_ key: AndroidKeyCode) {
        guard isControlReady else { return }
        if isIPhoneTarget, key != .home, key != .power { return }
        for packet in ControlPacket.keyPress(key) {
            guard sendControl(packet, transport: .ordered) == .sent else {
                return
            }
        }
    }

    func sendRotate() {
        guard selectedDeviceTarget.supportsAndroidNavigation,
              isControlReady,
              activePointers.isEmpty else { return }
        beginRotationDimensionWait()
        guard sendControl(ControlPacket.rotate, transport: .ordered) == .sent else {
            cancelRotationDimensionWait()
            refreshControlReadiness()
            return
        }
    }

    func requestKeyframe() {
        _ = sendControl(
            ControlPacket.requestKeyframe,
            transport: .ordered,
            reconnectWhenUnavailable: state == .connected
        )
    }

    func pasteText(_ text: String) {
        guard isControlReady, !text.isEmpty else { return }
        clipboardSequence &+= 1
        _ = sendControl(
            ControlPacket.setClipboard(
                text: text,
                sequence: clipboardSequence,
                paste: true
            ),
            transport: .ordered
        )
    }

    func requestRemoteClipboard() {
        guard selectedDeviceTarget.supportsAndroidNavigation,
              isControlReady else { return }
        _ = sendControl(
            ControlPacket.requestClipboard(),
            transport: .ordered
        )
    }

    private func handleMicrophoneControlMessage(_ data: Data) {
        if let demand = try? JSONDecoder().decode(
            MicrophoneDemandMessage.self,
            from: data
        ), demand.isValid {
            handleMicrophoneDemand(demand)
            return
        }

        guard let feedback = try? JSONDecoder().decode(
            MicrophoneStateFeedback.self,
            from: data
        ), feedback.version == 1,
           feedback.type == "microphoneState",
           let activeGeneration = microphoneActivationGeneration,
           feedback.generation == nil || feedback.generation == activeGeneration
        else {
            return
        }

        switch feedback.state {
        case "active":
            microphoneAcknowledgementTask?.cancel()
            microphoneAcknowledgementTask = nil
            microphoneAcknowledgedGeneration = activeGeneration
            microphoneRetryAttempt = 0
            diagnostics.microphoneInputState = "正在传输"
            diagnostics.microphoneLastError = nil
            logger.info(
                "Remote microphone input active for generation \(activeGeneration, privacy: .public)"
            )
        case "idle", "ready", "busy", "unavailable":
            // Generation-bound feedback may stop only the matching activation.
            // Unscoped legacy feedback is ignored so it cannot roll back a newer
            // demand after a rapid active/idle/active transition.
            guard feedback.generation != nil else { return }
            scheduleAutomaticMicrophoneRetry(
                generation: activeGeneration,
                state: "等待重试",
                error: "远端未接受当前音频输入（\(feedback.state)）"
            )
        default:
            break
        }
    }

    private func handleMicrophoneDemand(_ demand: MicrophoneDemandMessage) {
        guard isAuthenticated, isIPhoneTarget else { return }

        if let current = microphoneDemand {
            if demand.generation == current.generation {
                if current.state == demand.state {
                    if current.state == .active {
                        reevaluateAutomaticMicrophoneInput()
                    }
                    return
                }

                // A brief RFB transport loss is surfaced as an idle snapshot,
                // then the recovered phone can replay active with the same
                // phone-side generation. Those are real state transitions, not
                // duplicate messages, so both idle -> active and active -> idle
                // must continue through the replacement path below.
            }

            // generation is a per-demand correlation token, not a process-wide
            // counter. The phone daemon may restart and choose a numerically
            // smaller token. Since this reliable DataChannel is ordered, every
            // different generation supersedes the current demand regardless of
            // numeric ordering.
            stopAutomaticMicrophoneInput(
                clearDemand: false,
                state: "已停止"
            )
        }

        microphoneDemand = MicrophoneDemandCursor(
            generation: demand.generation,
            state: demand.state
        )
        microphonePermissionDeniedGeneration = nil
        microphoneRetryAttempt = 0
        diagnostics.microphoneDemandGeneration = demand.generation
        diagnostics.microphoneLastError = nil

        switch demand.state {
        case .active:
            diagnostics.microphoneInputState = "启动中"
            reevaluateAutomaticMicrophoneInput()
        case .idle:
            diagnostics.microphoneInputState = "已停止"
            resumeDeferredConnectionChangeIfPossible()
        }
    }

    private var canActivateAutomaticMicrophoneInput: Bool {
        isAuthenticated
            && appIsActive
            && isIPhoneTarget
            && state == .connected
            && peerConnected
            && isMicrophoneControlReady
            && (capabilities?.canMicrophoneInput ?? true)
    }

    private var hasActiveMicrophoneDemand: Bool {
        microphoneDemand?.state == .active
    }

    private func reevaluateAutomaticMicrophoneInput() {
        guard let demand = microphoneDemand, demand.state == .active else {
            if microphoneActivationGeneration != nil {
                stopAutomaticMicrophoneInput(clearDemand: false, state: "已停止")
            }
            return
        }
        guard canActivateAutomaticMicrophoneInput else {
            if microphoneActivationGeneration != nil || microphoneActivationTask != nil {
                stopAutomaticMicrophoneInput(clearDemand: false, state: "已暂停")
            }
            return
        }
        guard microphoneActivationGeneration != demand.generation,
              microphoneActivationTask == nil,
              microphoneRetryTask == nil,
              microphonePermissionDeniedGeneration != demand.generation,
              let webRTC else {
            return
        }

        // A second peer connection would share the same global VoiceProcessingIO
        // unit. Route probes are discarded and deferred while microphone RTP is
        // active so the audio session cannot be reconfigured underneath it.
        discardCandidate(markFailure: false)

        let token = UUID()
        let expectedConnectionGeneration = connectionGeneration
        microphoneActivationToken = token
        diagnostics.microphoneInputState = "等待系统授权"
        microphoneActivationTask = Task { [weak self, weak webRTC] in
            guard let self, let webRTC else { return }
            let permissionGranted = await self.requestMicrophonePermissionIfNeeded()
            guard !Task.isCancelled,
                  self.microphoneActivationToken == token,
                  self.connectionGeneration == expectedConnectionGeneration,
                  self.webRTC === webRTC,
                  self.canActivateAutomaticMicrophoneInput,
                  self.microphoneDemand?.generation == demand.generation,
                  self.microphoneDemand?.state == .active
            else {
                return
            }

            guard permissionGranted else {
                self.microphoneActivationTask = nil
                self.microphoneActivationToken = nil
                self.microphonePermissionDeniedGeneration = demand.generation
                self.diagnostics.microphoneInputState = "权限不可用"
                self.diagnostics.microphoneLastError = "系统麦克风权限未授予"
                self.logger.error(
                    "Microphone permission unavailable for generation \(demand.generation, privacy: .public)"
                )
                return
            }

            self.diagnostics.microphoneInputState = "启动中"
            guard webRTC.setLocalMicrophoneSending(true),
                  let acceptance = MicrophonePacket.demandAcceptance(
                    generation: demand.generation
                  )
            else {
                self.scheduleAutomaticMicrophoneRetry(
                    generation: demand.generation,
                    state: "启动失败",
                    error: "WebRTC 麦克风音轨无法挂载"
                )
                return
            }

            self.microphoneActivationGeneration = demand.generation
            let result = webRTC.sendMicrophoneControlJSON(acceptance)
            guard result == .sent else {
                if result == .droppedForBackpressure {
                    self.scheduleAutomaticMicrophoneRetry(
                        generation: demand.generation,
                        state: "等待重试",
                        error: "麦克风控制通道暂时拥塞"
                    )
                } else {
                    self.handleDataChannelsUnavailable(forceReconnect: true)
                }
                return
            }

            self.microphoneActivationTask = nil
            self.microphoneActivationToken = nil
            self.diagnostics.microphoneInputState = "等待远端确认"
            self.armMicrophoneAcknowledgementTimeout(
                demandGeneration: demand.generation,
                connectionGeneration: expectedConnectionGeneration
            )
        }
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func armMicrophoneAcknowledgementTimeout(
        demandGeneration: UInt64,
        connectionGeneration: UUID
    ) {
        microphoneAcknowledgementTask?.cancel()
        microphoneAcknowledgementTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.connectionGeneration == connectionGeneration,
                  self.microphoneActivationGeneration == demandGeneration,
                  self.microphoneAcknowledgedGeneration != demandGeneration
            else {
                return
            }
            self.scheduleAutomaticMicrophoneRetry(
                generation: demandGeneration,
                state: "确认超时",
                error: "远端未在 2 秒内确认音频输入"
            )
        }
    }

    private func scheduleAutomaticMicrophoneRetry(
        generation: UInt64,
        state: String,
        error: String
    ) {
        guard microphoneDemand?.generation == generation,
              microphoneDemand?.state == .active,
              microphonePermissionDeniedGeneration != generation
        else {
            return
        }

        microphoneRetryTask?.cancel()
        let retryToken = UUID()
        microphoneRetryToken = retryToken
        deactivateAutomaticMicrophoneTransport()

        let delayIndex = min(
            microphoneRetryAttempt,
            Self.microphoneRetryDelays.count - 1
        )
        let delay = Self.microphoneRetryDelays[delayIndex]
        microphoneRetryAttempt = min(
            microphoneRetryAttempt + 1,
            Self.microphoneRetryDelays.count - 1
        )
        let expectedConnectionGeneration = connectionGeneration

        diagnostics.microphoneInputState = state
        diagnostics.microphoneLastError = error
        logger.error(
            "Automatic microphone input retry scheduled for generation \(generation, privacy: .public), attempt \(delayIndex + 1, privacy: .public): \(error, privacy: .public)"
        )

        microphoneRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.microphoneRetryToken == retryToken,
                  self.connectionGeneration == expectedConnectionGeneration,
                  self.microphoneDemand?.generation == generation,
                  self.microphoneDemand?.state == .active,
                  self.isAuthenticated,
                  self.appIsActive
            else {
                return
            }
            self.microphoneRetryTask = nil
            self.microphoneRetryToken = nil
            self.reevaluateAutomaticMicrophoneInput()
        }
    }

    private func deactivateAutomaticMicrophoneTransport() {
        microphoneActivationToken = nil
        microphoneActivationTask?.cancel()
        microphoneActivationTask = nil
        microphoneAcknowledgementTask?.cancel()
        microphoneAcknowledgementTask = nil
        _ = webRTC?.setLocalMicrophoneSending(false)
        microphoneActivationGeneration = nil
        microphoneAcknowledgedGeneration = nil
    }

    private func stopAutomaticMicrophoneInput(
        clearDemand: Bool,
        state: String,
        error: String? = nil
    ) {
        microphoneRetryToken = nil
        microphoneRetryTask?.cancel()
        microphoneRetryTask = nil
        deactivateAutomaticMicrophoneTransport()

        if clearDemand {
            microphoneDemand = nil
            microphonePermissionDeniedGeneration = nil
            microphoneRetryAttempt = 0
            diagnostics.microphoneDemandGeneration = nil
        }
        diagnostics.microphoneInputState = isIPhoneTarget ? state : nil
        if let error {
            diagnostics.microphoneLastError = error
            logger.error("Automatic microphone input stopped: \(error, privacy: .public)")
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            let isReturningFromInterruption = wasAwayFromForeground
            appIsActive = true
            wasAwayFromForeground = false
            isObscured = false
            UIApplication.shared.isIdleTimerDisabled = isAuthenticated
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                // A permission denial is terminal only while the OS still reports
                // it. Returning from Settings with permission granted re-arms the
                // same demand generation without requiring a new phone event.
                microphonePermissionDeniedGeneration = nil
            }
            if isAuthenticated, needsForegroundReconnect || !isConnected {
                needsForegroundReconnect = false
                startConnection(reconnecting: true)
            } else {
                reevaluateAutomaticMicrophoneInput()
            }
            if isReturningFromInterruption,
               !privacyModeEnabled,
               isAuthenticated {
                showsNonPrivacyModeNotice = true
            }
        case .inactive:
            appIsActive = false
            wasAwayFromForeground = true
            if privacyModeEnabled {
                stopAutomaticMicrophoneInput(clearDemand: false, state: "已暂停")
            }
            // In privacy mode, hide the remote screen behind the calculator as
            // soon as the app is interrupted so the app-switcher snapshot never
            // reveals it.
            isObscured = privacyModeEnabled && isAuthenticated
            UIApplication.shared.isIdleTimerDisabled = false
        case .background:
            appIsActive = false
            wasAwayFromForeground = true
            needsForegroundReconnect = false
            if privacyModeEnabled {
                stopAutomaticMicrophoneInput(clearDemand: true, state: "已停止")
                lockForPrivacy()
            } else {
                // Keep the WebRTC peer, signaling socket and media tracks alive.
                // The audio background mode keeps the audio session active while
                // the app is outside the foreground.
                isObscured = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
        @unknown default:
            break
        }
    }

    private func startConnection(reconnecting: Bool) {
        guard isAuthenticated, connectionLifecycleAllowed,
              !isSwitchingDeviceConnection else { return }
        startDeviceConnectionMonitor()
        guard networkIsSatisfied else {
            state = .waitingForNetwork
            return
        }

        stopConnection(keepState: true)
        let generation = UUID()
        connectionGeneration = generation
        adaptivePolicy.prepareForPrimaryConnection(at: Date())
        let profile = adaptivePolicy.profileForNextConnection(at: Date())
        activeProfile = profile
        activeIceMode = .relay
        diagnostics.streamProfile = profile.displayName
        resetPerConnectionDiagnostics()
        state = reconnecting ? .reconnecting : .preparing
        needsForegroundReconnect = false
        UIApplication.shared.isIdleTimerDisabled = true
        beginConnectionDeadlines(generation: generation)
        setConnectionPhase(.fetchingIceConfiguration, generation: generation)

        connectionTask = Task { [weak self] in
            guard let self else { return }
            await self.establishConnection(
                generation: generation,
                profile: profile
            )
        }
    }

    private func establishConnection(
        generation: UUID,
        profile: RemoteStreamProfile
    ) async {
        var stage = "fetch_ice"
        let connectStart = Date()
        func mark(_ label: String) {
            NSLog("RH_CONN %@ +%.0fms", label, Date().timeIntervalSince(connectStart) * 1000)
        }
        do {
            state = .preparing
            logger.info("Connection attempt started")
            mark("start")
            let ice = try await portal.fetchIceConfiguration()
            mark("ice_fetched")
            logger.info("ICE configuration received: \(ice.iceServers.count, privacy: .public) servers")
            try Task.checkCancellation()
            guard generation == connectionGeneration else { return }

            stage = "prepare_peer"
            let webRTC = WebRTCClient()
            configureCallbacks(for: webRTC, generation: generation)
            try webRTC.prepare(
                iceServers: ice.iceServers,
                relayOnly: true,
                supportsMicrophoneSending: isIPhoneTarget,
                initialRemoteAudioMuted: false
            )
            self.webRTC = webRTC
            logger.info("Peer connection prepared")

            // The gateway session is independent of the local offer and also costs
            // a Hong Kong round-trip, so fetch it concurrently with ICE gathering
            // instead of after it.
            async let gatewaySessionTask = portal.fetchGatewaySession()

            stage = "create_offer"
            setConnectionPhase(.gatheringIce, generation: generation)
            state = .signaling
            let offer = try await webRTC.createOfferWaitingForIce()
            mark("offer_ready")
            logger.info("Local offer ready")
            try Task.checkCancellation()
            guard generation == connectionGeneration else { return }

            stage = "fetch_gateway_session"
            setConnectionPhase(.fetchingGatewaySession, generation: generation)
            let gateway = try await gatewaySessionTask
            let socketURL = try await portal.trustedWebSocketURL(
                from: gateway.websocketUrl
            )
            mark("gateway_session")
            logger.info("Gateway session received")

            stage = "open_websocket"
            setConnectionPhase(.openingWebSocket, generation: generation)
            let signaling = SignalingSocket()
            configureCallbacks(for: signaling, generation: generation)
            self.signaling = signaling
            let socketRequest = await portal.websocketRequest(url: socketURL)
            try await signaling.connect(request: socketRequest)
            signalingIsOpen = true
            mark("websocket_open")
            logger.info("Signaling socket opened")
            try Task.checkCancellation()

            stage = "send_offer"
            let config = gatewayConfiguration(
                sdp: offer,
                iceMode: .relay,
                streamProfile: profile
            )
            try await signaling.sendJSON(config)
            mark("offer_sent")
            logger.info("Local offer sent")
            if state != .connected {
                state = .connecting
            }
            let nextPhase: ConnectionPhase
            if peerConnected {
                nextPhase = .waitingForMedia
            } else if remoteAnswerApplied {
                nextPhase = .waitingForPeer
            } else {
                nextPhase = .waitingForAnswer
            }
            setConnectionPhase(nextPhase, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            guard generation == connectionGeneration else { return }
            logger.error(
                "Connection attempt failed at \(stage, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            handleConnectionFailure(error)
        }
    }

    private func configureCallbacks(for client: WebRTCClient, generation: UUID) {
        client.onConnectionStateChange = { [weak self] connectionState in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                self.handlePeerState(connectionState)
            }
        }

        client.onVideoTrack = { [weak self] track in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                self.videoTrack = track
            }
        }

        client.onVideoSizeChange = { [weak self] size in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                self.applyRemoteVideoDimensions(
                    width: Int(size.width.rounded()),
                    height: Int(size.height.rounded())
                )
            }
        }

        client.onVideoFrameDecoded = { [weak self] decodedAt in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                self.handleDecodedVideoFrame(at: decodedAt)
            }
        }

        client.onDataChannelsReady = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                self.dataChannelsReady = true
                self.refreshControlReadiness()
                self.requestKeyframe()
            }
        }

        client.onDataChannelsUnavailable = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                self.handleDataChannelsUnavailable()
            }
        }

        client.onMicrophoneChannelsReadyChange = { [weak self] ready in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                self.isMicrophoneControlReady = ready
                if ready {
                    self.reevaluateAutomaticMicrophoneInput()
                } else {
                    // microphone-control is part of the session contract. Once
                    // it has opened, losing it cannot be repaired independently
                    // of SDP/DataChannel negotiation, so rebuild the whole peer.
                    // WebRTCClient suppresses the initial closed state and emits
                    // false only after this channel previously reported open.
                    self.handleDataChannelsUnavailable(forceReconnect: true)
                }
            }
        }

        client.onMicrophoneFeedback = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                self.handleMicrophoneControlMessage(data)
            }
        }

        client.onAudioSessionRecoveryFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                self.scheduleReconnect(reason: error)
            }
        }

        isMicrophoneControlReady = client.microphoneChannelsReady

        client.onFirstFramesReady = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                NSLog("RH_CONN first_frames_ready")
                self.firstFramesReady = true
                self.refreshControlReadiness()
            }
        }

        client.onControlFeedback = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                self.handleControlFeedback(data)
            }
        }
    }

    private func configureCallbacks(for socket: SignalingSocket, generation: UUID) {
        socket.onMessage = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                await self.handleGatewayMessage(data)
            }
        }

        socket.onClose = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.connectionGeneration,
                      self.connectionLifecycleAllowed,
                      self.isAuthenticated
                else {
                    return
                }
                self.signalingIsOpen = false
                self.scheduleReconnect(reason: error)
            }
        }
    }

    private func handleGatewayMessage(_ data: Data) async {
        do {
            let message = try JSONDecoder().decode(GatewaySignal.self, from: data)
            if message.status == "error" {
                throw PortalError.server(
                    statusCode: 502,
                    message: message.message ?? "远程设备连接失败"
                )
            }

            switch message.stage {
            case "webrtc_init":
                guard let sdp = message.sdp else {
                    throw WebRTCClient.ClientError.invalidRemoteDescription
                }
                guard let webRTC else {
                    throw WebRTCClient.ClientError.peerConnectionUnavailable
                }
                try await webRTC.setRemoteAnswer(sdp)
                remoteAnswerApplied = true
                setConnectionPhase(
                    peerConnected ? .waitingForMedia : .waitingForPeer,
                    generation: connectionGeneration
                )
            case "webrtc_metainfo":
                capabilities = message.capabilities
                mediaMetadata = message.mediaMeta
                applyControlProtocolVersion(message.controlProtocolVersion)
                if let width = message.mediaMeta?.width,
                   let height = message.mediaMeta?.height {
                    applyRemoteVideoDimensions(width: width, height: height)
                }
                refreshControlReadiness()
                requestKeyframe()
            default:
                break
            }
        } catch {
            handleConnectionFailure(error)
        }
    }

    private func handlePeerState(_ peerState: WebRTCClient.ConnectionState) {
        logger.info("Peer state changed: \(String(describing: peerState), privacy: .public)")
        switch peerState {
        case .new:
            break
        case .checking:
            if state != .signaling {
                state = .connecting
            }
        case .connected:
            let becameConnected = state != .connected
            peerConnected = true
            disconnectGraceTask?.cancel()
            disconnectGraceTask = nil
            state = .connected
            loginMessage = nil
            reconnectAttempt = 0
            UserDefaults.standard.set(
                selectedDeviceTarget.id,
                forKey: Self.lastConnectedDeviceDefaultsKey
            )
            UserDefaults.standard.set(selectedDeviceTarget.id, forKey: Self.selectedDeviceDefaultsKey)
            if becameConnected {
                adaptivePolicy.registerPrimaryConnection(
                    profile: activeProfile,
                    iceMode: activeIceMode,
                    at: Date()
                )
                diagnostics.streamProfile = activeProfile.displayName
            }
            setConnectionPhase(.waitingForMedia, generation: connectionGeneration)
            refreshControlReadiness()
            startStatisticsLoop()
            requestKeyframe()
        case .disconnected:
            stopAutomaticMicrophoneInput(clearDemand: true, state: "连接已中断")
            peerConnected = false
            state = .reconnecting
            isControlReady = false
            disconnectGraceTask?.cancel()
            disconnectGraceTask = Task { [weak self] in
                try? await Task.sleep(for: AppConfiguration.peerDisconnectGracePeriod)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.state != .connected else { return }
                    self.scheduleReconnect(reason: nil)
                }
            }
        case .failed, .closed:
            stopAutomaticMicrophoneInput(clearDemand: true, state: "连接已中断")
            peerConnected = false
            scheduleReconnect(reason: nil)
        }
    }

    private func scheduleReconnect(reason: Error?) {
        guard reconnectTask == nil, isAuthenticated, connectionLifecycleAllowed,
              !isSwitchingDeviceConnection else { return }
        stopAutomaticMicrophoneInput(clearDemand: true, state: "正在重连")
        cancelConnectionDeadlines()
        isControlReady = false
        state = networkIsSatisfied ? .reconnecting : .waitingForNetwork
        if let reason {
            lastGatewayMessage = userFacingMessage(for: reason)
        }
        let delays: [Duration] = [
            .milliseconds(900),
            .seconds(2),
            .seconds(5),
            .seconds(10),
            .seconds(30)
        ]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.reconnectTask = nil
                self.startConnection(reconnecting: true)
            }
        }
    }

    private func handleConnectionFailure(_ error: Error) {
        cancelConnectionDeadlines()
        if case PortalError.unauthorized = error {
            stopConnection()
            isAuthenticated = false
            UIApplication.shared.isIdleTimerDisabled = false
            loginMessage = "登录已过期，请重新输入密码"
            loginMessageIsError = true
            return
        }
        lastGatewayMessage = userFacingMessage(for: error)
        state = .failed(lastGatewayMessage ?? "连接失败")
        scheduleReconnect(reason: error)
    }

    private func stopConnection(keepState: Bool = false) {
        stopAutomaticMicrophoneInput(clearDemand: true, state: "已停止")
        connectionGeneration = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        disconnectGraceTask?.cancel()
        disconnectGraceTask = nil
        statsTask?.cancel()
        statsTask = nil
        cancelConnectionDeadlines()
        cancelRotationDimensionWait()
        signaling?.close()
        signaling = nil
        webRTC?.close()
        webRTC = nil
        discardCandidate(markFailure: false)
        videoTrack = nil
        mediaMetadata = nil
        capabilities = nil
        lastStatsSample = nil
        dataChannelsReady = false
        firstFramesReady = false
        peerConnected = false
        remoteAnswerApplied = false
        signalingIsOpen = false
        isControlReady = false
        isMicrophoneControlReady = false
        controlSequence = 0
        controlProtocolVersion = nil
        didFallbackToLegacyControl = false
        controlDriverFailures.removeAll()
        lastControlAcknowledgementSequence = 0
        lastFrameFeedbackSequence = 0
        pendingDecodedFrameFeedback = nil
        pendingAdaptiveReconnect = nil
        activePointers.removeAll()
        iPhonePrimaryPointerID = nil
        if !keepState {
            resetDeviceConnection()
            state = .signedOut
        }
    }

    private func handleNetworkChange(
        _ snapshot: NetworkMonitor.Snapshot,
        previous: NetworkMonitor.Snapshot?
    ) {
        diagnostics.network = snapshot.interface.rawValue
        networkIsSatisfied = snapshot.isSatisfied

        guard let previous else { return }
        guard isAuthenticated, connectionLifecycleAllowed else { return }

        if !snapshot.isSatisfied {
            state = .waitingForNetwork
            stopConnection(keepState: true)
        } else if !previous.isSatisfied || snapshot.interface != previous.interface {
            reconnectAttempt = 0
            startConnection(reconnecting: true)
        }
    }

    private func startStatisticsLoop() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let client = self.webRTC else { return }
                if let report = await client.statistics() {
                    await MainActor.run {
                        self.consumeStatistics(report)
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func consumeStatistics(_ report: RTCStatisticsReport) {
        var inbound: RTCStatistics?
        var outboundAudio: RTCStatistics?
        var candidatePair: RTCStatistics?
        var localCandidate: RTCStatistics?
        var remoteCandidate: RTCStatistics?

        for statistic in report.statistics.values {
            if statistic.type == "inbound-rtp",
               (
                   (statistic.values["kind"] as? String) == "video"
                       || (statistic.values["mediaType"] as? String) == "video"
                       || number(statistic.values["framesDecoded"]) != nil
               ) {
                inbound = statistic
            } else if statistic.type == "outbound-rtp",
                      (
                          (statistic.values["kind"] as? String) == "audio"
                              || (statistic.values["mediaType"] as? String) == "audio"
                      ) {
                outboundAudio = statistic
            } else if statistic.type == "candidate-pair",
                      (statistic.values["state"] as? String) == "succeeded",
                      boolean(statistic.values["nominated"]) == true {
                candidatePair = statistic
            }
        }

        if let localCandidateID = candidatePair?.values["localCandidateId"] as? String {
            localCandidate = report.statistics[localCandidateID]
        }
        if let remoteCandidateID = candidatePair?.values["remoteCandidateId"] as? String {
            remoteCandidate = report.statistics[remoteCandidateID]
        }

        let now = Date()
        if let outboundAudio {
            if let packets = number(outboundAudio.values["packetsSent"]) {
                diagnostics.microphonePacketsSent = Int64(
                    max(0, packets).rounded(.down)
                )
            }
            if let bytes = number(outboundAudio.values["bytesSent"]) {
                diagnostics.microphoneBytesSent = Int64(
                    max(0, bytes).rounded(.down)
                )
            }
        }
        var route: RemoteIceMode?
        var roundTripMilliseconds: Double?
        if let candidatePair {
            diagnostics.candidatePairState = candidatePair.values["state"] as? String
            if let seconds = number(candidatePair.values["currentRoundTripTime"]) {
                roundTripMilliseconds = seconds * 1_000
                diagnostics.roundTripMilliseconds = roundTripMilliseconds
            }
        }
        let usesRelay = (localCandidate?.values["candidateType"] as? String) == "relay"
            || (remoteCandidate?.values["candidateType"] as? String) == "relay"
        if candidatePair != nil {
            route = usesRelay ? .relay : .direct
            diagnostics.route = usesRelay ? "TURN 中继" : "直连"
            diagnostics.localCandidateType =
                localCandidate?.values["candidateType"] as? String
            diagnostics.remoteCandidateType =
                remoteCandidate?.values["candidateType"] as? String
            diagnostics.transportProtocol =
                localCandidate?.values["protocol"] as? String
            diagnostics.relayProtocol =
                localCandidate?.values["relayProtocol"] as? String
        }

        guard let inbound else {
            diagnostics.lastUpdated = now
            return
        }

        let bytes = number(inbound.values["bytesReceived"]) ?? 0
        let packetsReceived = number(inbound.values["packetsReceived"]) ?? 0
        let packetsLost = number(inbound.values["packetsLost"]) ?? 0
        let frames = number(inbound.values["framesDecoded"]) ?? 0
        let jitterBufferDelay = number(inbound.values["jitterBufferDelay"])
        let jitterBufferEmittedCount = number(
            inbound.values["jitterBufferEmittedCount"]
        )
        var bitrateBitsPerSecond: Double?
        var framesPerSecond: Double?
        var packetLossRate: Double?
        var jitterBufferDelayMilliseconds: Double?

        if let last = lastStatsSample {
            let interval = now.timeIntervalSince(last.date)
            if interval > 0 {
                bitrateBitsPerSecond = counterDelta(bytes, last.bytesReceived)
                    .map { $0 * 8 / interval }
                framesPerSecond = counterDelta(frames, last.framesDecoded)
                    .map { $0 / interval }
            }
            let receivedDelta = counterDelta(
                packetsReceived,
                last.packetsReceived
            )
            let lostDelta = counterDelta(packetsLost, last.packetsLost)
            if let receivedDelta,
               let lostDelta,
               receivedDelta + lostDelta > 0 {
                packetLossRate = lostDelta / (receivedDelta + lostDelta)
            }

            if let jitterBufferDelay,
               let jitterBufferEmittedCount,
               let previousDelay = last.jitterBufferDelay,
               let previousCount = last.jitterBufferEmittedCount {
                let delayDelta = counterDelta(
                    jitterBufferDelay,
                    previousDelay
                )
                let emittedDelta = counterDelta(
                    jitterBufferEmittedCount,
                    previousCount
                )
                if let delayDelta, let emittedDelta, emittedDelta > 0 {
                    jitterBufferDelayMilliseconds =
                        delayDelta / emittedDelta * 1_000
                }
            }
        }

        lastStatsSample = StatsSample(
            date: now,
            bytesReceived: bytes,
            packetsReceived: packetsReceived,
            packetsLost: packetsLost,
            framesDecoded: frames,
            jitterBufferDelay: jitterBufferDelay,
            jitterBufferEmittedCount: jitterBufferEmittedCount
        )

        if let bitrateBitsPerSecond {
            diagnostics.receivedBitrateKbps = bitrateBitsPerSecond / 1_000
        }
        if let framesPerSecond {
            diagnostics.receivedFramesPerSecond = framesPerSecond
        }
        if let packetLossRate {
            diagnostics.packetLossPercent = packetLossRate * 100
        }
        if let jitterBufferDelayMilliseconds {
            diagnostics.jitterBufferDelayMilliseconds =
                jitterBufferDelayMilliseconds
        }
        if let jitter = number(inbound.values["jitter"]) {
            diagnostics.jitterMilliseconds = jitter * 1_000
        }
        if let dropped = number(inbound.values["framesDropped"]) {
            diagnostics.framesDropped = Int64(dropped)
        }
        diagnostics.framesDecoded = Int64(frames)

        let width = number(inbound.values["frameWidth"])
        let height = number(inbound.values["frameHeight"])
        if let width, let height {
            applyRemoteVideoDimensions(
                width: Int(width.rounded()),
                height: Int(height.rounded())
            )
        }

        let healthSample = ConnectionHealthSample(
            date: now,
            route: route,
            roundTripMilliseconds: roundTripMilliseconds,
            jitterMilliseconds: number(inbound.values["jitter"]).map { $0 * 1_000 },
            bitrateBitsPerSecond: bitrateBitsPerSecond,
            packetLossRate: packetLossRate,
            framesDecoded: frames,
            framesDropped: number(inbound.values["framesDropped"]),
            keyFramesDecoded: number(inbound.values["keyFramesDecoded"]),
            freezeCount: number(inbound.values["freezeCount"]),
            jitterBufferDelayMilliseconds: jitterBufferDelayMilliseconds,
            width: width,
            height: height
        )
        if let request = adaptivePolicy.consume(
            healthSample,
            canStartCandidate: candidate == nil
                && state == .connected
                && connectionLifecycleAllowed
                && networkIsSatisfied
                && activePointers.isEmpty
                && !hasActiveMicrophoneDemand
        ) {
            handleAdaptiveConnectionRequest(
                request,
                generation: connectionGeneration
            )
        }
        diagnostics.lastUpdated = now
    }

    private func handleControlFeedback(_ data: Data) {
        if let telemetry = ControlTelemetryFeedback.decode(data) {
            guard controlProtocolVersion == 1 else { return }
            switch telemetry {
            case let .acknowledgement(acknowledgement):
                consumeControlAcknowledgement(acknowledgement)
            case let .frame(frame):
                consumeControlFrameFeedback(frame)
            }
            return
        }

        guard let type = data.first else { return }
        if type == 0x69 {
            let payload = Data(data.dropFirst())
            guard let route = try? JSONDecoder().decode(
                GatewayRouteTelemetry.self,
                from: payload
            ) else {
                return
            }
            consumeGatewayDiagnostics(route)
            return
        }

        let payload = data.dropFirst()
        let text = String(data: payload, encoding: .utf8)
        if type == 0x17 {
            remoteClipboardText = text
        } else if type == 0x64 {
            lastGatewayMessage = text
        } else if type == 0x65 {
            lastGatewayMessage = text
            guard let healthCode = text,
                  let request = adaptivePolicy.encoderFallbackRequest(
                      healthCode: healthCode,
                      at: Date()
                  )
            else {
                return
            }
            discardCandidate(markFailure: false)
            handleAdaptiveConnectionRequest(
                request,
                generation: connectionGeneration
            )
        }
    }

    private func consumeGatewayDiagnostics(
        _ telemetry: GatewayRouteTelemetry
    ) {
        switch telemetry.event {
        case "ice_route":
            updateGatewayRoute(from: telemetry)
        case "control_diagnostics":
            if telemetryHasRouteEvidence(telemetry) {
                updateGatewayRoute(from: telemetry)
            }
            updateGatewayAgentState(
                prefix: "运行中",
                profile: telemetry.streamProfile
            )
        case "agent_active", "agent_profile_adopted":
            updateGatewayAgentState(
                prefix: "运行中",
                profile: telemetry.streamProfile
            )
        case "agent_restarting":
            updateGatewayAgentState(
                prefix: "正在切换",
                profile: telemetry.streamProfile
            )
        case "agent_restart_failed":
            updateGatewayAgentState(
                prefix: "切换失败，正在回退",
                profile: telemetry.streamProfile
            )
        default:
            break
        }
    }

    private func updateGatewayRoute(
        from telemetry: GatewayRouteTelemetry
    ) {
        diagnostics.gatewayRoute = nonempty(telemetry.route)
        diagnostics.gatewayLocalCandidateType =
            nonempty(telemetry.localCandidateType)
        diagnostics.gatewayRemoteCandidateType =
            nonempty(telemetry.remoteCandidateType)
        diagnostics.gatewayTransportProtocol =
            nonempty(telemetry.`protocol`)
        diagnostics.gatewayRelayProtocol =
            nonempty(telemetry.relayProtocol)
        if let roundTrip = telemetry.rttMs,
           roundTrip.isFinite,
           roundTrip >= 0 {
            diagnostics.gatewayRoundTripMilliseconds = roundTrip
        } else {
            diagnostics.gatewayRoundTripMilliseconds = nil
        }
    }

    private func telemetryHasRouteEvidence(
        _ telemetry: GatewayRouteTelemetry
    ) -> Bool {
        nonempty(telemetry.route) != nil
            || nonempty(telemetry.localCandidateType) != nil
            || nonempty(telemetry.remoteCandidateType) != nil
    }

    private func updateGatewayAgentState(
        prefix: String,
        profile: String?
    ) {
        if let profile = nonempty(profile) {
            let description =
                RemoteStreamProfile(rawValue: profile)?.displayName ?? profile
            diagnostics.gatewayAgentState = "\(prefix) · \(description)"
        } else {
            diagnostics.gatewayAgentState = prefix
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func refreshControlReadiness() {
        isControlReady = state == .connected
            && !deviceConnectionIsBusy
            && dataChannelsReady
            && firstFramesReady
            && !isAwaitingRotationDimensions
            && (mediaMetadata?.width ?? 0) > 0
            && (mediaMetadata?.height ?? 0) > 0

        if isControlReady {
            cancelConnectionDeadlines()
            if signalingIsOpen {
                reconnectTask?.cancel()
                reconnectTask = nil
            }
        } else if peerConnected, connectionTotalDeadlineTask != nil {
            setConnectionPhase(
                .waitingForMedia,
                generation: connectionGeneration
            )
        }
        reevaluateAutomaticMicrophoneInput()
    }

    @discardableResult
    private func sendControl(
        _ legacyPayload: Data,
        transport: ControlTransport,
        reconnectWhenUnavailable: Bool = true
    ) -> WebRTCClient.SendResult {
        guard let webRTC else {
            if reconnectWhenUnavailable {
                handleDataChannelsUnavailable()
            }
            return .channelUnavailable
        }

        let packet = controlProtocolVersion == 1
            ? makeControlEnvelope(legacyPayload)
            : legacyPayload
        let result: WebRTCClient.SendResult
        switch transport {
        case .ordered:
            result = webRTC.sendOrdered(packet)
        case .transient:
            result = webRTC.sendTransient(packet)
        }

        if result == .channelUnavailable, reconnectWhenUnavailable {
            handleDataChannelsUnavailable()
        }
        return result
    }

    private func makeControlEnvelope(_ legacyPayload: Data) -> Data {
        controlSequence &+= 1
        return ControlPacket.envelope(
            legacyPayload: legacyPayload,
            sequence: controlSequence,
            clientMonotonicMicroseconds: Self.monotonicMicroseconds(),
            requestsFrameFeedback: ControlPacket.shouldRequestFrameFeedback(
                for: legacyPayload
            )
        )
    }

    private func handleDataChannelsUnavailable(forceReconnect: Bool = false) {
        let wasUsable = dataChannelsReady || isControlReady
        stopAutomaticMicrophoneInput(
            clearDemand: true,
            state: "控制通道已断开"
        )
        dataChannelsReady = false
        isControlReady = false
        activePointers.removeAll()
        iPhonePrimaryPointerID = nil

        guard (wasUsable || forceReconnect),
              isAuthenticated,
              connectionLifecycleAllowed else { return }
        scheduleReconnect(reason: SessionControllerError.controlChannelClosed)
    }

    private func consumeControlAcknowledgement(
        _ acknowledgement: ControlAcknowledgement
    ) {
        guard controlProtocolVersion == 1 else { return }
        guard acknowledgement.sequence > 0,
              acknowledgement.sequence <= controlSequence
        else {
            return
        }

        switch acknowledgement.status {
        case 3, 5:
            activateLegacyControlFallback()
        case 4:
            if acknowledgement.sequence > lastControlAcknowledgementSequence {
                recordControlDriverFailure(
                    sequence: acknowledgement.sequence,
                    at: Date()
                )
            }
        default:
            if acknowledgement.sequence > lastControlAcknowledgementSequence {
                controlDriverFailures.removeAll()
            }
            break
        }

        guard acknowledgement.sequence >= lastControlAcknowledgementSequence else {
            return
        }
        lastControlAcknowledgementSequence = acknowledgement.sequence
        let now = Self.monotonicMicroseconds()
        diagnostics.controlAcknowledgementRoundTripMilliseconds =
            Self.elapsedMilliseconds(
                from: acknowledgement.clientMonotonicMicroseconds,
                to: now
            )
        diagnostics.gatewayDriverWriteMilliseconds =
            Self.elapsedMilliseconds(
                from: acknowledgement.gatewayReceivedMicroseconds,
                to: acknowledgement.driverWriteMicroseconds
            )
        diagnostics.lastControlAcknowledgementSucceeded =
            acknowledgement.status == 0
        diagnostics.lastControlAcknowledgementStatus =
            Self.controlAcknowledgementStatusLabel(
                acknowledgement.status
            )
    }

    private func applyControlProtocolVersion(_ advertisedVersion: Int?) {
        guard !didFallbackToLegacyControl else {
            controlProtocolVersion = 0
            diagnostics.controlProtocol = "Legacy · 兼容回退"
            return
        }
        controlProtocolVersion = advertisedVersion == 1 ? 1 : 0
        diagnostics.controlProtocol = controlProtocolVersion == 1
            ? "v1 · 有确认"
            : "Legacy · 无确认"
        controlDriverFailures.removeAll()
    }

    private func activateLegacyControlFallback() {
        guard controlProtocolVersion == 1 else { return }
        didFallbackToLegacyControl = true
        controlProtocolVersion = 0
        controlDriverFailures.removeAll()
        pendingDecodedFrameFeedback = nil
        diagnostics.controlProtocol = "Legacy · 兼容回退"
        diagnostics.controlAcknowledgementRoundTripMilliseconds = nil
        diagnostics.gatewayDriverWriteMilliseconds = nil
        diagnostics.nextFrameFeedbackRoundTripMilliseconds = nil
        diagnostics.gatewayNextFrameAfterWriteMilliseconds = nil
        diagnostics.decodedFrameConfirmationRoundTripMilliseconds = nil
    }

    private func recordControlDriverFailure(
        sequence: UInt64,
        at now: Date
    ) {
        controlDriverFailures.removeAll {
            now.timeIntervalSince($0.date) > 5
        }
        guard !controlDriverFailures.contains(where: {
            $0.sequence == sequence
        }) else {
            return
        }
        controlDriverFailures.append(
            ControlDriverFailure(sequence: sequence, date: now)
        )
        guard controlDriverFailures.count >= 3 else { return }
        controlDriverFailures.removeAll()
        scheduleReconnect(
            reason: SessionControllerError.controlDriverFailed
        )
    }

    private func consumeControlFrameFeedback(
        _ frame: ControlFrameFeedback
    ) {
        guard frame.status == 0,
              frame.sequence > 0,
              frame.sequence <= controlSequence,
              frame.sequence >= lastFrameFeedbackSequence
        else {
            return
        }
        lastFrameFeedbackSequence = frame.sequence
        let now = Self.monotonicMicroseconds()
        diagnostics.nextFrameFeedbackRoundTripMilliseconds =
            Self.elapsedMilliseconds(
                from: frame.clientMonotonicMicroseconds,
                to: now
            )
        diagnostics.gatewayNextFrameAfterWriteMilliseconds =
            Self.elapsedMilliseconds(
                from: frame.driverWriteMicroseconds,
                to: frame.frameSeenMicroseconds
            )
        pendingDecodedFrameFeedback = PendingDecodedFrameFeedback(
            sequence: frame.sequence,
            clientMonotonicMicroseconds: frame.clientMonotonicMicroseconds
        )
        webRTC?.armDecodedFrameConfirmation()
    }

    private func handleDecodedVideoFrame(at decodedAt: UInt64) {
        guard let pending = pendingDecodedFrameFeedback,
              decodedAt >= pending.clientMonotonicMicroseconds
        else {
            return
        }
        diagnostics.decodedFrameConfirmationRoundTripMilliseconds =
            Self.elapsedMilliseconds(
                from: pending.clientMonotonicMicroseconds,
                to: decodedAt
            )
        pendingDecodedFrameFeedback = nil
    }

    private func beginRotationDimensionWait() {
        rotationMetadataDeadlineTask?.cancel()
        rotationBaselineSize = currentRemoteSize
        isAwaitingRotationDimensions = true
        refreshControlReadiness()
        let generation = connectionGeneration
        rotationMetadataDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: AppConfiguration.rotationMetadataTimeout
                )
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard generation == self.connectionGeneration,
                  self.isAwaitingRotationDimensions
            else {
                return
            }
            self.rotationMetadataDeadlineTask = nil
            self.cancelRotationDimensionWait()
            self.refreshControlReadiness()
            self.requestKeyframe()
        }
    }

    private func cancelRotationDimensionWait() {
        rotationMetadataDeadlineTask?.cancel()
        rotationMetadataDeadlineTask = nil
        isAwaitingRotationDimensions = false
        rotationBaselineSize = nil
    }

    private func applyRemoteVideoDimensions(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let previous = mediaMetadata
        if previous?.width != width || previous?.height != height {
            mediaMetadata = RemoteMediaMetadata(
                videoCodec: previous?.videoCodec,
                width: width,
                height: height,
                fps: previous?.fps,
                audioCodec: previous?.audioCodec
            )
        }
        diagnostics.resolution = "\(width) × \(height)"

        if isAwaitingRotationDimensions {
            let updated = CGSize(width: width, height: height)
            if rotationBaselineSize == nil || updated != rotationBaselineSize {
                cancelRotationDimensionWait()
            }
        }
        refreshControlReadiness()
    }

    private var currentRemoteSize: CGSize? {
        guard let width = mediaMetadata?.width,
              let height = mediaMetadata?.height,
              width > 0,
              height > 0
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private func beginConnectionDeadlines(generation: UUID) {
        cancelConnectionDeadlines()
        connectionTotalDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: AppConfiguration.connectionTotalTimeout
                )
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard generation == self.connectionGeneration,
                  !self.isControlReady
            else {
                return
            }
            self.connectionDidTimeOut(
                generation: generation,
                phase: self.connectionPhase,
                isTotalDeadline: true
            )
        }
    }

    private func resetPerConnectionDiagnostics() {
        diagnostics.route = "TURN 中继"
        diagnostics.localCandidateType = nil
        diagnostics.remoteCandidateType = nil
        diagnostics.transportProtocol = nil
        diagnostics.relayProtocol = nil
        diagnostics.gatewayRoute = nil
        diagnostics.gatewayLocalCandidateType = nil
        diagnostics.gatewayRemoteCandidateType = nil
        diagnostics.gatewayTransportProtocol = nil
        diagnostics.gatewayRelayProtocol = nil
        diagnostics.gatewayRoundTripMilliseconds = nil
        diagnostics.gatewayAgentState = nil
        diagnostics.controlProtocol = "协商中"
        diagnostics.roundTripMilliseconds = nil
        diagnostics.jitterMilliseconds = nil
        diagnostics.jitterBufferDelayMilliseconds = nil
        diagnostics.receivedFramesPerSecond = nil
        diagnostics.receivedBitrateKbps = nil
        diagnostics.packetLossPercent = nil
        diagnostics.resolution = nil
        diagnostics.framesDropped = nil
        diagnostics.framesDecoded = nil
        diagnostics.candidatePairState = nil
        diagnostics.controlAcknowledgementRoundTripMilliseconds = nil
        diagnostics.gatewayDriverWriteMilliseconds = nil
        diagnostics.nextFrameFeedbackRoundTripMilliseconds = nil
        diagnostics.gatewayNextFrameAfterWriteMilliseconds = nil
        diagnostics.decodedFrameConfirmationRoundTripMilliseconds = nil
        diagnostics.lastControlAcknowledgementSucceeded = nil
        diagnostics.lastControlAcknowledgementStatus = nil
        diagnostics.microphoneInputState = isIPhoneTarget ? "等待远端" : nil
        diagnostics.microphoneDemandGeneration = nil
        diagnostics.microphonePacketsSent = nil
        diagnostics.microphoneBytesSent = nil
        diagnostics.microphoneLastError = nil
        diagnostics.lastUpdated = nil
    }

    private func setConnectionPhase(
        _ phase: ConnectionPhase,
        generation: UUID
    ) {
        guard generation == connectionGeneration,
              connectionTotalDeadlineTask != nil,
              !isControlReady
        else {
            return
        }
        connectionPhase = phase
        connectionPhaseDeadlineTask?.cancel()
        connectionPhaseDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: phase.timeout)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard generation == self.connectionGeneration,
                  self.connectionPhase == phase,
                  !self.isControlReady
            else {
                return
            }
            self.connectionDidTimeOut(
                generation: generation,
                phase: phase,
                isTotalDeadline: false
            )
        }
    }

    private func cancelConnectionDeadlines() {
        connectionPhaseDeadlineTask?.cancel()
        connectionPhaseDeadlineTask = nil
        connectionTotalDeadlineTask?.cancel()
        connectionTotalDeadlineTask = nil
        connectionPhase = nil
    }

    private func connectionDidTimeOut(
        generation: UUID,
        phase: ConnectionPhase?,
        isTotalDeadline: Bool
    ) {
        guard generation == connectionGeneration else { return }
        logger.error(
            "Connection deadline exceeded: phase=\(phase?.logName ?? "unknown", privacy: .public), total=\(isTotalDeadline, privacy: .public)"
        )
        handleConnectionFailure(SessionControllerError.connectionTimedOut)
    }

    nonisolated private static func monotonicMicroseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000
    }

    nonisolated private static func elapsedMilliseconds(
        from earlier: UInt64,
        to later: UInt64
    ) -> Double? {
        guard later >= earlier else { return nil }
        return Double(later - earlier) / 1_000
    }

    nonisolated private static func controlAcknowledgementStatusLabel(
        _ status: UInt8
    ) -> String {
        switch status {
        case 0:
            return "已写入设备"
        case 1:
            return "已丢弃过时动作"
        case 2:
            return "已丢弃缺少按下的动作"
        case 3:
            return "指令格式无效"
        case 4:
            return "设备写入失败"
        case 5:
            return "远端不支持此指令"
        default:
            return "未知状态 \(status)"
        }
    }

    private func gatewayConfiguration(
        sdp: String,
        iceMode: RemoteIceMode,
        streamProfile: RemoteStreamProfile
    ) -> [String: Any] {
        let target = selectedDeviceTarget
        var driverConfiguration: [String: Any] = [
            "video_codec": "h264",
            "audio": "true",
            "control": "true"
        ]
        if target.type == .android {
            driverConfiguration.merge([
                "video_encoder": streamProfile.videoEncoder,
                "video_bit_rate": streamProfile.videoBitrate,
                "video_codec_options":
                    "i-frame-interval=\(AppConfiguration.videoKeyframeIntervalSeconds),bitrate-mode=2",
                "max_size": String(AppConfiguration.preferredVideoSize),
                "max_fps": String(streamProfile.maximumFrameRate)
            ]) { _, newValue in newValue }
        } else {
            driverConfiguration["microphone"] = "true"
        }

        return [
            "device_type": target.type.rawValue,
            "device_id": target.id,
            "device_ip": "0",
            "device_port": "0",
            "av_sync": false,
            "use_local_timestamp": false,
            "ice_mode": iceMode.rawValue,
            "stream_profile": streamProfile.rawValue,
            "driver_config": driverConfiguration,
            "sdp": sdp
        ]
    }

    private func handleAdaptiveConnectionRequest(
        _ request: ConnectionCandidateRequest,
        generation: UUID
    ) {
        guard generation == connectionGeneration,
              !deviceConnectionIsBusy,
              state == .connected,
              connectionLifecycleAllowed,
              networkIsSatisfied
        else {
            return
        }

        if hasActiveMicrophoneDemand {
            if request.purpose != .routeProbe {
                pendingAdaptiveReconnect = request
            }
            return
        }

        if request.purpose == .routeProbe {
            guard request.streamProfile == activeProfile else { return }
            startCandidate(request, generation: generation)
            return
        }

        if !activePointers.isEmpty {
            pendingAdaptiveReconnect = request
            return
        }

        pendingAdaptiveReconnect = nil
        discardCandidate(markFailure: false)
        adaptivePolicy.selectPreferredProfileForReconnect(
            request.streamProfile,
            at: Date()
        )
        startConnection(reconnecting: true)
    }

    private func startCandidate(
        _ request: ConnectionCandidateRequest,
        generation: UUID
    ) {
        guard generation == connectionGeneration,
              !deviceConnectionIsBusy,
              request.purpose == .routeProbe,
              request.streamProfile == activeProfile,
              state == .connected,
              connectionLifecycleAllowed,
              networkIsSatisfied,
              !hasActiveMicrophoneDemand,
              candidate == nil
        else {
            return
        }

        let candidate = ConnectionCandidate(
            request: request,
            generation: generation,
            client: WebRTCClient(),
            socket: SignalingSocket()
        )
        self.candidate = candidate
        configureCandidateCallbacks(for: candidate)

        candidate.timeoutTask = Task { [weak self, weak candidate] in
            try? await Task.sleep(
                for: AppConfiguration.candidateConnectionTimeout
            )
            guard !Task.isCancelled, let self, let candidate else { return }
            guard self.candidate === candidate else { return }
            self.discardCandidate(markFailure: true)
        }
        candidate.operationTask = Task { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            await self.establishCandidate(candidate)
        }
    }

    private func establishCandidate(_ candidate: ConnectionCandidate) async {
        do {
            let ice = try await portal.fetchIceConfiguration()
            try Task.checkCancellation()
            guard self.candidate === candidate,
                  candidate.generation == connectionGeneration
            else {
                return
            }

            let iceServers: [IceServerPayload]
            if candidate.request.iceMode == .direct {
                iceServers = ice.iceServers.compactMap { server in
                    let urls = server.urls.filter {
                        $0.lowercased().hasPrefix("stun:")
                    }
                    return urls.isEmpty ? nil : IceServerPayload(urls: urls)
                }
                guard !iceServers.isEmpty else {
                    throw PortalError.malformedPayload
                }
            } else {
                iceServers = ice.iceServers
            }

            try candidate.client.prepare(
                iceServers: iceServers,
                relayOnly: candidate.request.iceMode == .relay,
                // Pre-negotiate the same dormant send/receive audio m-line as
                // the primary iPhone connection. The local sender remains nil
                // and its track disabled throughout candidate validation, so
                // no microphone capture occurs until this candidate is
                // promoted and a generation-bound remote demand arrives.
                supportsMicrophoneSending: isIPhoneTarget,
                initialRemoteAudioMuted: true
            )
            let offer = try await candidate.client.createOfferWaitingForIce()
            try Task.checkCancellation()
            guard self.candidate === candidate,
                  candidate.generation == connectionGeneration
            else {
                return
            }

            let gateway = try await portal.fetchGatewaySession()
            let socketURL = try await portal.trustedWebSocketURL(
                from: gateway.websocketUrl
            )
            let socketRequest = await portal.websocketRequest(url: socketURL)
            try await candidate.socket.connect(request: socketRequest)
            try Task.checkCancellation()
            guard self.candidate === candidate else { return }
            try await candidate.socket.sendJSON(
                gatewayConfiguration(
                    sdp: offer,
                    iceMode: candidate.request.iceMode,
                    streamProfile: candidate.request.streamProfile
                )
            )
        } catch is CancellationError {
            return
        } catch {
            guard self.candidate === candidate else { return }
            discardCandidate(markFailure: true)
        }
    }

    private func configureCandidateCallbacks(for candidate: ConnectionCandidate) {
        let client = candidate.client
        client.onConnectionStateChange = { [weak self, weak candidate] peerState in
            Task { @MainActor [weak self, weak candidate] in
                guard let self,
                      let candidate,
                      self.candidate === candidate,
                      candidate.generation == self.connectionGeneration
                else {
                    return
                }
                switch peerState {
                case .connected:
                    candidate.peerConnected = true
                    self.evaluateCandidateReadiness(candidate)
                case .disconnected, .failed, .closed:
                    self.discardCandidate(markFailure: true)
                case .new, .checking:
                    break
                }
            }
        }
        client.onVideoTrack = { [weak self, weak candidate] track in
            Task { @MainActor [weak self, weak candidate] in
                guard let self,
                      let candidate,
                      self.candidate === candidate
                else {
                    return
                }
                candidate.videoTrack = track
                self.evaluateCandidateReadiness(candidate)
            }
        }
        client.onDataChannelsReady = { [weak self, weak candidate] in
            Task { @MainActor [weak self, weak candidate] in
                guard let self,
                      let candidate,
                      self.candidate === candidate
                else {
                    return
                }
                candidate.channelsReady = true
                self.requestCandidateKeyframeIfReady(candidate)
                self.evaluateCandidateReadiness(candidate)
            }
        }
        client.onDataChannelsUnavailable = { [weak self, weak candidate] in
            Task { @MainActor [weak self, weak candidate] in
                guard let self,
                      let candidate,
                      self.candidate === candidate
                else {
                    return
                }
                self.discardCandidate(markFailure: true)
            }
        }
        if isIPhoneTarget {
            client.onMicrophoneChannelsReadyChange = { [weak self, weak candidate] ready in
                Task { @MainActor [weak self, weak candidate] in
                    guard let self,
                          let candidate,
                          self.candidate === candidate,
                          candidate.generation == self.connectionGeneration
                    else {
                        return
                    }

                    if ready {
                        self.evaluateCandidateReadiness(candidate)
                    } else {
                        // WebRTCClient suppresses the initial closed state, so
                        // false here means this candidate's microphone-control
                        // channel opened and was subsequently lost. It is not a
                        // promotable iPhone session anymore.
                        self.discardCandidate(markFailure: true)
                    }
                }
            }
        }
        client.onFirstFramesReady = { [weak self, weak candidate] in
            Task { @MainActor [weak self, weak candidate] in
                guard let self,
                      let candidate,
                      self.candidate === candidate
                else {
                    return
                }
                candidate.framesReady = true
                self.evaluateCandidateReadiness(candidate)
            }
        }
        client.onControlFeedback = { [weak self, weak candidate] data in
            Task { @MainActor [weak self, weak candidate] in
                guard let self,
                      let candidate,
                      self.candidate === candidate,
                      data.first == 0x65
                else {
                    return
                }
                self.discardCandidate(markFailure: true)
            }
        }
        client.onAudioSessionRecoveryFailure = { [weak self, weak candidate] _ in
            Task { @MainActor [weak self, weak candidate] in
                guard let self,
                      let candidate,
                      self.candidate === candidate
                else {
                    return
                }
                self.discardCandidate(markFailure: true)
            }
        }

        let socket = candidate.socket
        socket.onMessage = { [weak self, weak candidate] data in
            Task { @MainActor [weak self, weak candidate] in
                guard let self,
                      let candidate,
                      self.candidate === candidate,
                      candidate.generation == self.connectionGeneration
                else {
                    return
                }
                do {
                    let message = try JSONDecoder().decode(
                        GatewaySignal.self,
                        from: data
                    )
                    if message.status == "error" {
                        throw PortalError.server(
                            statusCode: 502,
                            message: message.message
                        )
                    }
                    switch message.stage {
                    case "webrtc_init":
                        guard let sdp = message.sdp else {
                            throw WebRTCClient.ClientError.invalidRemoteDescription
                        }
                        try await candidate.client.setRemoteAnswer(sdp)
                    case "webrtc_metainfo":
                        candidate.capabilities = message.capabilities
                        candidate.mediaMetadata = message.mediaMeta
                        candidate.controlProtocolVersion =
                            message.controlProtocolVersion == 1 ? 1 : 0
                        self.requestCandidateKeyframeIfReady(candidate)
                        self.evaluateCandidateReadiness(candidate)
                    default:
                        break
                    }
                } catch {
                    guard self.candidate === candidate else { return }
                    self.discardCandidate(markFailure: true)
                }
            }
        }
        socket.onClose = { [weak self, weak candidate] _ in
            Task { @MainActor [weak self, weak candidate] in
                guard let self,
                      let candidate,
                      self.candidate === candidate
                else {
                    return
                }
                self.discardCandidate(markFailure: true)
            }
        }
    }

    private func requestCandidateKeyframeIfReady(
        _ candidate: ConnectionCandidate
    ) {
        guard self.candidate === candidate,
              candidate.channelsReady,
              candidate.controlProtocolVersion != nil,
              !candidate.didRequestKeyframe
        else {
            return
        }
        candidate.didRequestKeyframe = true
        let packet = candidate.controlProtocolVersion == 1
            ? makeControlEnvelope(ControlPacket.requestKeyframe)
            : ControlPacket.requestKeyframe
        _ = candidate.client.sendOrdered(packet)
    }

    private func evaluateCandidateReadiness(_ candidate: ConnectionCandidate) {
        guard self.candidate === candidate,
              candidate.validationTask == nil,
              candidate.peerConnected,
              candidate.channelsReady,
              (!isIPhoneTarget || candidate.client.microphoneChannelsReady),
              candidate.videoTrack != nil,
              (candidate.mediaMetadata?.width ?? 0) > 0,
              (candidate.mediaMetadata?.height ?? 0) > 0
        else {
            return
        }

        candidate.validationTask = Task { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            var roundTrips: [Double] = []
            var jitterSamples: [Double] = []
            var previousFrames: Double?
            var consecutiveFrameAdvances = 0
            let startedAt = Date()

            while !Task.isCancelled,
                  Date().timeIntervalSince(startedAt) < 6 {
                guard self.candidate === candidate,
                      candidate.generation == self.connectionGeneration
                else {
                    return
                }
                if let report = await candidate.client.statistics(),
                   let snapshot = Self.mediaSnapshot(in: report) {
                    if let roundTrip = snapshot.roundTripMilliseconds {
                        roundTrips.append(roundTrip)
                        if roundTrips.count > 5 {
                            roundTrips.removeFirst()
                        }
                    }
                    if let jitter = snapshot.jitterMilliseconds {
                        jitterSamples.append(jitter)
                        if jitterSamples.count > 5 {
                            jitterSamples.removeFirst()
                        }
                    }

                    if let previousFrames {
                        consecutiveFrameAdvances = snapshot.framesDecoded > previousFrames
                            ? consecutiveFrameAdvances + 1
                            : 0
                    }
                    previousFrames = snapshot.framesDecoded

                    let routeMatches = snapshot.route == candidate.request.iceMode
                    let keyframeReady = snapshot.keyFramesDecoded.map { $0 > 0 } ?? true
                    let dimensionsReady =
                        (snapshot.width ?? Double(candidate.mediaMetadata?.width ?? 0)) > 0
                        && (snapshot.height ?? Double(candidate.mediaMetadata?.height ?? 0)) > 0
                    let frameEvidenceReady = consecutiveFrameAdvances >= 3
                        || (
                            candidate.framesReady
                                && snapshot.framesDecoded >= 3
                                && Date().timeIntervalSince(startedAt) >= 2
                        )

                    if routeMatches,
                       candidate.framesReady,
                       keyframeReady,
                       dimensionsReady,
                       frameEvidenceReady,
                       roundTrips.count >= 3 {
                        finishCandidateValidation(
                            candidate,
                            roundTripMilliseconds: Self.median(roundTrips),
                            jitterMilliseconds: Self.median(jitterSamples)
                        )
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }

            guard !Task.isCancelled, self.candidate === candidate else { return }
            discardCandidate(markFailure: true)
        }
    }

    private func finishCandidateValidation(
        _ candidate: ConnectionCandidate,
        roundTripMilliseconds: Double?,
        jitterMilliseconds: Double?
    ) {
        guard self.candidate === candidate else { return }

        if candidate.request.purpose == .routeProbe {
            guard candidate.request.iceMode == .direct,
                  let candidateRoundTrip = roundTripMilliseconds,
                  let activeRoundTrip = adaptivePolicy.activeRoundTripMedian(),
                  (jitterMilliseconds ?? 0) < 80,
                  candidateRoundTrip + 20 < activeRoundTrip
            else {
                discardCandidate(markFailure: false)
                return
            }
        }

        candidate.selectedRoundTripMilliseconds = roundTripMilliseconds
        candidate.selectedJitterMilliseconds = jitterMilliseconds
        candidate.readyForPromotion = true
        candidate.timeoutTask?.cancel()
        candidate.timeoutTask = nil
        if activePointers.isEmpty, !hasActiveMicrophoneDemand {
            promoteCandidate()
        }
    }

    private func promoteCandidate() {
        guard let candidate,
              candidate.readyForPromotion,
              !hasActiveMicrophoneDemand,
              (!isIPhoneTarget || candidate.client.microphoneChannelsReady),
              let newTrack = candidate.videoTrack,
              let newMetadata = candidate.mediaMetadata
        else {
            return
        }

        stopAutomaticMicrophoneInput(clearDemand: true, state: "切换连接")
        let oldClient = webRTC
        let oldSocket = signaling
        let newClient = candidate.client
        let newSocket = candidate.socket

        // Candidate audio is muted from prepare through validation. Hand over
        // playout without any overlap: silence the old primary first, then make
        // the already-ready candidate audible before publishing its references.
        oldClient?.setRemoteAudioMuted(true)
        newClient.setRemoteAudioMuted(false)

        oldClient?.detachCallbacks()
        oldSocket?.onMessage = nil
        oldSocket?.onClose = nil
        candidate.operationTask?.cancel()
        candidate.timeoutTask?.cancel()
        candidate.validationTask?.cancel()
        candidate.operationTask = nil
        candidate.timeoutTask = nil
        candidate.validationTask = nil
        self.candidate = nil

        disconnectGraceTask?.cancel()
        disconnectGraceTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        state = .connected
        loginMessage = nil

        webRTC = newClient
        signaling = newSocket
        videoTrack = newTrack
        mediaMetadata = newMetadata
        capabilities = candidate.capabilities
        didFallbackToLegacyControl = false
        controlProtocolVersion = candidate.controlProtocolVersion ?? 0
        activeProfile = candidate.request.streamProfile
        activeIceMode = candidate.request.iceMode
        adaptivePolicy.registerPromotion(
            profile: activeProfile,
            iceMode: activeIceMode,
            at: Date()
        )

        diagnostics.streamProfile = activeProfile.displayName
        diagnostics.controlProtocol = controlProtocolVersion == 1
            ? "v1 · 有确认"
            : "Legacy · 无确认"
        diagnostics.route = activeIceMode == .relay ? "TURN 中继" : "直连"
        diagnostics.resolution = "\(newMetadata.width ?? 0) × \(newMetadata.height ?? 0)"
        if let roundTrip = candidate.selectedRoundTripMilliseconds {
            diagnostics.roundTripMilliseconds = roundTrip
        }
        if let jitter = candidate.selectedJitterMilliseconds {
            diagnostics.jitterMilliseconds = jitter
        }
        lastStatsSample = nil
        controlDriverFailures.removeAll()
        pendingDecodedFrameFeedback = nil
        peerConnected = true
        signalingIsOpen = true
        cancelRotationDimensionWait()

        configureCallbacks(for: newClient, generation: connectionGeneration)
        configureCallbacks(for: newSocket, generation: connectionGeneration)
        if isIPhoneTarget, !newClient.microphoneChannelsReady {
            // Close the narrow race where microphone-control drops after the
            // promotion guard but before the primary callbacks take ownership.
            // At this point the candidate is already the published primary, so
            // use the normal primary reconnect path instead of leaving a session
            // that can never service a later automatic microphone demand.
            oldSocket?.close()
            oldClient?.close()
            scheduleReconnect(reason: SessionControllerError.controlChannelClosed)
            return
        }
        dataChannelsReady = true
        firstFramesReady = true
        refreshControlReadiness()
        startStatisticsLoop()
        requestKeyframe()

        Task {
            try? await Task.sleep(for: .milliseconds(250))
            oldSocket?.close()
            oldClient?.close()
        }
    }

    private func discardCandidate(markFailure: Bool) {
        guard let candidate else { return }
        self.candidate = nil
        if markFailure {
            adaptivePolicy.markCandidateFailure(
                purpose: candidate.request.purpose,
                at: Date()
            )
        }
        candidate.operationTask?.cancel()
        candidate.timeoutTask?.cancel()
        candidate.validationTask?.cancel()
        candidate.operationTask = nil
        candidate.timeoutTask = nil
        candidate.validationTask = nil
        candidate.client.detachCallbacks()
        candidate.client.close()
        candidate.socket.onMessage = nil
        candidate.socket.onClose = nil
        candidate.socket.close()
    }

    nonisolated private static func mediaSnapshot(
        in report: RTCStatisticsReport
    ) -> CandidateMediaSnapshot? {
        var inbound: RTCStatistics?
        var selectedPair: RTCStatistics?

        let selectedPairID = report.statistics.values
            .first(where: { $0.type == "transport" })?
            .values["selectedCandidatePairId"] as? String
        if let selectedPairID {
            selectedPair = report.statistics[selectedPairID]
        }

        for statistic in report.statistics.values {
            if statistic.type == "inbound-rtp",
               (
                   (statistic.values["kind"] as? String) == "video"
                       || (statistic.values["mediaType"] as? String) == "video"
                       || Self.statisticNumber(statistic.values["framesDecoded"]) != nil
               ) {
                inbound = statistic
            } else if selectedPair == nil,
                      statistic.type == "candidate-pair",
                      (statistic.values["state"] as? String) == "succeeded",
                      (
                          Self.statisticBoolean(statistic.values["nominated"]) == true
                              || Self.statisticBoolean(statistic.values["selected"]) == true
                      ) {
                selectedPair = statistic
            }
        }

        guard let inbound, let selectedPair else { return nil }
        let localID = selectedPair.values["localCandidateId"] as? String
        let remoteID = selectedPair.values["remoteCandidateId"] as? String
        let localCandidate = localID.flatMap { report.statistics[$0] }
        let remoteCandidate = remoteID.flatMap { report.statistics[$0] }
        let usesRelay =
            (localCandidate?.values["candidateType"] as? String) == "relay"
            || (remoteCandidate?.values["candidateType"] as? String) == "relay"

        return CandidateMediaSnapshot(
            route: usesRelay ? .relay : .direct,
            roundTripMilliseconds: Self.statisticNumber(
                selectedPair.values["currentRoundTripTime"]
            ).map { $0 * 1_000 },
            jitterMilliseconds: Self.statisticNumber(
                inbound.values["jitter"]
            ).map { $0 * 1_000 },
            framesDecoded: Self.statisticNumber(
                inbound.values["framesDecoded"]
            ) ?? 0,
            keyFramesDecoded: Self.statisticNumber(
                inbound.values["keyFramesDecoded"]
            ),
            width: Self.statisticNumber(inbound.values["frameWidth"]),
            height: Self.statisticNumber(inbound.values["frameHeight"])
        )
    }

    nonisolated private static func statisticNumber(_ value: NSObject?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    nonisolated private static func statisticBoolean(_ value: NSObject?) -> Bool? {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1":
                return true
            case "false", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    nonisolated private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func counterDelta(_ current: Double, _ previous: Double) -> Double? {
        guard current >= previous else { return nil }
        return current - previous
    }

    private func boolean(_ value: NSObject?) -> Bool? {
        Self.statisticBoolean(value)
    }

    private func number(_ value: NSObject?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "当前没有可用网络"
            case NSURLErrorTimedOut:
                return "连接服务器超时"
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
                return "无法连接服务器"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private static func normalizedServerURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              components.host != nil
        else {
            return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

private struct MicrophoneDemandCursor {
    let generation: UInt64
    let state: MicrophoneDemandMessage.State
}

private struct StatsSample {
    let date: Date
    let bytesReceived: Double
    let packetsReceived: Double
    let packetsLost: Double
    let framesDecoded: Double
    let jitterBufferDelay: Double?
    let jitterBufferEmittedCount: Double?
}

private struct CandidateMediaSnapshot {
    let route: RemoteIceMode
    let roundTripMilliseconds: Double?
    let jitterMilliseconds: Double?
    let framesDecoded: Double
    let keyFramesDecoded: Double?
    let width: Double?
    let height: Double?
}

private enum ControlTransport {
    case ordered
    case transient
}

private enum ConnectionPhase: Equatable {
    case fetchingIceConfiguration
    case gatheringIce
    case fetchingGatewaySession
    case openingWebSocket
    case waitingForAnswer
    case waitingForPeer
    case waitingForMedia

    var timeout: Duration {
        switch self {
        case .fetchingIceConfiguration, .fetchingGatewaySession:
            return AppConfiguration.portalStageTimeout
        case .gatheringIce:
            return AppConfiguration.iceGatheringStageTimeout
        case .openingWebSocket:
            return AppConfiguration.websocketStageTimeout
        case .waitingForAnswer:
            return AppConfiguration.answerStageTimeout
        case .waitingForPeer:
            return AppConfiguration.peerStageTimeout
        case .waitingForMedia:
            return AppConfiguration.mediaStageTimeout
        }
    }

    var logName: String {
        switch self {
        case .fetchingIceConfiguration:
            return "fetch_ice"
        case .gatheringIce:
            return "gather_ice"
        case .fetchingGatewaySession:
            return "fetch_gateway_session"
        case .openingWebSocket:
            return "open_websocket"
        case .waitingForAnswer:
            return "wait_answer"
        case .waitingForPeer:
            return "wait_peer"
        case .waitingForMedia:
            return "wait_media"
        }
    }
}

private enum SessionControllerError: LocalizedError {
    case connectionTimedOut
    case controlChannelClosed
    case controlDriverFailed

    var errorDescription: String? {
        switch self {
        case .connectionTimedOut:
            return "连接设备超时，正在重试"
        case .controlChannelClosed:
            return "控制通道已断开，正在恢复"
        case .controlDriverFailed:
            return "远端设备写入失败，正在恢复连接"
        }
    }
}

private struct ControlDriverFailure {
    let sequence: UInt64
    let date: Date
}

private struct PendingDecodedFrameFeedback {
    let sequence: UInt64
    let clientMonotonicMicroseconds: UInt64
}

private final class ConnectionCandidate {
    let request: ConnectionCandidateRequest
    let generation: UUID
    let client: WebRTCClient
    let socket: SignalingSocket

    var operationTask: Task<Void, Never>?
    var timeoutTask: Task<Void, Never>?
    var validationTask: Task<Void, Never>?
    var videoTrack: RTCVideoTrack?
    var mediaMetadata: RemoteMediaMetadata?
    var capabilities: RemoteCapabilities?
    var controlProtocolVersion: Int?
    var didRequestKeyframe = false
    var peerConnected = false
    var channelsReady = false
    var framesReady = false
    var readyForPromotion = false
    var selectedRoundTripMilliseconds: Double?
    var selectedJitterMilliseconds: Double?

    init(
        request: ConnectionCandidateRequest,
        generation: UUID,
        client: WebRTCClient,
        socket: SignalingSocket
    ) {
        self.request = request
        self.generation = generation
        self.client = client
        self.socket = socket
    }
}
