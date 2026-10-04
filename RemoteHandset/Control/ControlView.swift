import SwiftUI

struct ControlView: View {
    @EnvironmentObject private var session: RemoteSessionController
    @State private var showsDiagnostics = false
    @State private var showsTextInput = false
    @State private var showsPrivacyModeConfirmation = false
    @State private var deviceBeingRenamed: DeviceTarget?
    @State private var controlsVisible = false

    private var remoteSize: CGSize {
        guard let width = session.mediaMetadata?.width,
              let height = session.mediaMetadata?.height,
              width > 0,
              height > 0
        else {
            return CGSize(width: 720, height: 1280)
        }
        return CGSize(width: width, height: height)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RemoteVideoSurface(
                videoTrack: session.videoTrack,
                remoteSize: remoteSize,
                isControlEnabled: session.isControlReady,
                onTouch: session.sendTouch,
                onSurfaceInteraction: hideControls
            )
            .ignoresSafeArea()

            if session.videoTrack == nil {
                connectionPlaceholder
            }

            floatingControlLayer
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .bottom)
        .sheet(isPresented: $showsDiagnostics) {
            DiagnosticsView(
                diagnostics: session.diagnostics,
                gatewayMessage: session.lastGatewayMessage,
                onReconnect: {
                    showsDiagnostics = false
                    session.reconnect()
                },
                onLogout: {
                    showsDiagnostics = false
                    session.logout()
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsTextInput) {
            TextInputView(
                destination: session.isIPhoneTarget ? .iPhone : .android,
                remoteClipboardText: session.remoteClipboardText,
                onPaste: session.pasteText,
                onRequestRemoteClipboard: session.requestRemoteClipboard
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $deviceBeingRenamed) { device in
            DeviceNameEditorView(device: device) { name in
                session.renameDevice(device, to: name)
            }
            .presentationDetents([.height(190)])
        }
        .alert("关闭隐私模式？", isPresented: $showsPrivacyModeConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认关闭", role: .destructive) {
                session.setPrivacyModeEnabled(false)
            }
        } message: {
            Text("关闭后，离开计算器时远程控制会保持连接，手机音频会继续播放，视频连接也不会因切换到其他 App 或回到桌面而主动断开。")
        }
        .alert(
            "当前处于非隐私模式",
            isPresented: Binding(
                get: { session.showsNonPrivacyModeNotice },
                set: { isPresented in
                    if !isPresented {
                        session.dismissNonPrivacyModeNotice()
                    }
                }
            )
        ) {
            Button("知道了") {
                session.dismissNonPrivacyModeNotice()
            }
        } message: {
            Text("离开计算器时，远程控制连接会保持，手机音频会继续播放，视频连接也不会主动断开。")
        }
    }

    // The controls float over the video without reserving layout space, so the
    // remote screen always fills the display. Empty regions of this layer stay
    // transparent to touches and pass them straight through to the video.
    private var floatingControlLayer: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if controlsVisible {
                controlsDock
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                CollapsedControlHandle(onExpand: showControls)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
    }

    private var connectionPlaceholder: some View {
        VStack(spacing: 14) {
            if session.state.isBusy || session.state == .waitingForNetwork {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            } else {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text(session.state.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if case .failed = session.state {
                Button("重新连接") {
                    session.reconnect()
                }
                .buttonStyle(.bordered)
            }
            if session.showsDeviceConnection {
                if session.deviceConnectionIsBusy {
                    Text("正在切换手机连接方式")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if session.deviceConnection?.preference != "wifi"
                            || session.deviceConnection?.activeTransport != "wifi" {
                    Button {
                        session.switchDeviceConnection(to: "wifi")
                    } label: {
                        Label("切换为无线连接", systemImage: "wifi")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!session.canSwitchToWireless)
                }
                if let message = session.deviceConnectionMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var controlsDock: some View {
        ControlDock(
            statusLabel: session.state.label,
            isConnected: session.isConnected,
            isEnabled: session.isControlReady,
            selectedDevice: session.selectedDeviceTarget,
            deviceTargets: session.availableDeviceTargets,
            privacyModeEnabled: session.privacyModeEnabled,
            deviceType: session.selectedDeviceTarget.type,
            deviceConnection: session.showsDeviceConnection ? session.deviceConnection : nil,
            connectionIsFresh: session.deviceConnectionIsFresh,
            connectionIsBusy: session.deviceConnectionIsBusy,
            connectionMessage: session.deviceConnectionMessage,
            onSelectConnection: session.switchDeviceConnection,
            onCollapse: hideControls,
            onSelectDevice: { target in
                session.switchDevice(to: target)
            },
            onRenameDevice: { target in
                deviceBeingRenamed = target
            },
            onPrivacyModeChanged: { enabled in
                guard !enabled else {
                    session.setPrivacyModeEnabled(true)
                    return
                }
                showsPrivacyModeConfirmation = true
            },
            onRefresh: session.requestKeyframe,
            onDiagnostics: { showsDiagnostics = true },
            onBack: { session.sendKey(.back) },
            onHome: { session.sendKey(.home) },
            onRecents: { session.sendKey(.appSwitch) },
            onRotate: session.sendRotate,
            onKeyboard: { showsTextInput = true },
            onPower: { session.sendKey(.power) },
            onVolumeDown: { session.sendKey(.volumeDown) },
            onVolumeUp: { session.sendKey(.volumeUp) }
        )
    }

    private func showControls() {
        withAnimation(.easeInOut(duration: 0.22)) {
            controlsVisible = true
        }
    }

    private func hideControls() {
        guard controlsVisible else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            controlsVisible = false
        }
    }
}

private struct DeviceNameEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let device: DeviceTarget
    let onSave: (String) -> Void
    @State private var name: String

    init(device: DeviceTarget, onSave: @escaping (String) -> Void) {
        self.device = device
        self.onSave = onSave
        _name = State(initialValue: device.displayName)
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("设备名称", text: $name)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
            }
            .navigationTitle("修改设备名称")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(normalizedName)
                        dismiss()
                    }
                    .disabled(normalizedName.isEmpty)
                }
            }
        }
    }
}
