import SwiftUI

struct ControlDock: View {
    let statusLabel: String
    let isConnected: Bool
    let isEnabled: Bool
    let selectedDevice: DeviceTarget
    let deviceTargets: [DeviceTarget]
    let privacyModeEnabled: Bool
    let deviceType: RemoteDeviceType
    let deviceConnection: DeviceConnectionStatus?
    let connectionIsFresh: Bool
    let connectionIsBusy: Bool
    let connectionMessage: String?
    let onSelectConnection: (String) -> Void
    let onCollapse: () -> Void
    let onSelectDevice: (DeviceTarget) -> Void
    let onRenameDevice: (DeviceTarget) -> Void
    let onPrivacyModeChanged: (Bool) -> Void
    let onRefresh: () -> Void
    let onDiagnostics: () -> Void
    let onBack: () -> Void
    let onHome: () -> Void
    let onRecents: () -> Void
    let onRotate: () -> Void
    let onKeyboard: () -> Void
    let onPower: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .overlay(.white.opacity(0.12))
            deviceSelector
            Divider()
                .overlay(.white.opacity(0.12))
            if deviceType == .android, let connection = deviceConnection,
               connection.wirelessConfigured {
                connectionSelector(connection)
                Divider()
                    .overlay(.white.opacity(0.12))
            }
            privacyModeToggle
            Divider()
                .overlay(.white.opacity(0.12))
            ControlToolbar(
                isEnabled: isEnabled,
                deviceType: deviceType,
                onBack: onBack,
                onHome: onHome,
                onRecents: onRecents,
                onRotate: onRotate,
                onKeyboard: onKeyboard,
                onPower: onPower,
                onVolumeDown: onVolumeDown,
                onVolumeUp: onVolumeUp
            )
        }
        .frame(maxWidth: 680)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(statusLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: 128, alignment: .leading)

                Spacer(minLength: 44)

                headerButton(
                    "arrow.clockwise",
                    accessibilityLabel: "刷新画面",
                    action: onRefresh
                )
                headerButton(
                    "waveform.path.ecg",
                    accessibilityLabel: "连接诊断",
                    action: onDiagnostics
                )
            }

            Button(action: onCollapse) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起控制栏")
        }
        .frame(maxWidth: 680)
        .frame(height: 50)
        .padding(.horizontal, 12)
    }

    private var deviceSelector: some View {
        HStack(spacing: 10) {
            Label("设备列表", systemImage: selectedDevice.type == .iPhoneUSB ? "iphone" : "rectangle.portrait")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            deviceMenu
        }
        .frame(maxWidth: 680)
        .frame(height: 42)
        .padding(.horizontal, 16)
    }

    private var privacyModeToggle: some View {
        Toggle(
            isOn: Binding(
                get: { privacyModeEnabled },
                set: onPrivacyModeChanged
            )
        ) {
            Label("隐私模式", systemImage: privacyModeEnabled ? "eye.slash" : "eye")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .tint(.green)
        .frame(maxWidth: 680)
        .frame(height: 42)
        .padding(.horizontal, 16)
        .accessibilityLabel("隐私模式")
        .accessibilityValue(privacyModeEnabled ? "已开启" : "已关闭")
    }

    private func connectionSelector(_ connection: DeviceConnectionStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label("连接方式", systemImage: "cable.connector")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if connectionIsBusy {
                    ProgressView().tint(.white)
                    Text("正在切换")
                        .font(.subheadline)
                } else {
                    Menu {
                        Button {
                            onSelectConnection("wifi")
                        } label: {
                            Label(
                                connection.wifiAvailable ? "切换为无线连接" : "无线暂不可用",
                                systemImage: connection.usesWirelessPreference ? "checkmark" : "wifi"
                            )
                        }
                        .disabled(!connectionIsFresh || !connection.wifiAvailable
                            || (connection.usesWirelessPreference && connection.activeTransport == "wifi"))
                        Button {
                            onSelectConnection("auto")
                        } label: {
                            Label("自动连接（有线优先）", systemImage: connection.preference == "auto" ? "checkmark" : "cable.connector")
                        }
                        .disabled(!connectionIsFresh || connection.preference == "auto")
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: connection.activeTransport == "wifi" ? "wifi" : "cable.connector")
                            Text(connectionIsFresh ? connection.transportLabel : "正在检查")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(minHeight: 36)
                        .padding(.horizontal, 10)
                        .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("手机连接方式，\(connection.transportLabel)")
                }
            }
            .frame(minHeight: 42)
            if let connectionMessage {
                Text(connectionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, 16)
    }

    private var deviceMenu: some View {
        Menu {
            ForEach(deviceTargets, id: \.id) { target in
                Button {
                    onSelectDevice(target)
                } label: {
                    if target == selectedDevice {
                        Label("\(target.displayName) · 当前", systemImage: "checkmark")
                    } else {
                        Text(target.displayName)
                    }
                }
            }
            Divider()
            Button {
                onRenameDevice(selectedDevice)
            } label: {
                Label("修改设备名称", systemImage: "pencil")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedDevice.type == .iPhoneUSB ? "iphone" : "rectangle.portrait")
                    .font(.system(size: 14, weight: .semibold))
                Text(selectedDevice.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(.white.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("设备列表，当前为\(selectedDevice.displayName)")
    }

    private func headerButton(
        _ symbol: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct ControlToolbar: View {
    let isEnabled: Bool
    let deviceType: RemoteDeviceType
    let onBack: () -> Void
    let onHome: () -> Void
    let onRecents: () -> Void
    let onRotate: () -> Void
    let onKeyboard: () -> Void
    let onPower: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void

    var body: some View {
        Group {
            if deviceType == .iPhoneUSB {
                iPhoneControls
            } else {
                androidControls
            }
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
    }

    private var androidControls: some View {
        HStack(spacing: 0) {
            controlButton("chevron.backward", label: "返回", action: onBack)
            controlDivider
            controlButton("circle", label: "主页", action: onHome)
            controlDivider
            controlButton("square.on.square", label: "任务", action: onRecents)
            controlDivider
            controlButton("keyboard", label: "键盘", action: onKeyboard)
            controlDivider
            moreMenu
            controlDivider
            controlButton("power", label: "电源", action: onPower)
        }
    }

    private var iPhoneControls: some View {
        HStack(spacing: 0) {
            controlButton("circle", label: "主页", action: onHome)
            controlDivider
            controlButton("keyboard", label: "键盘", action: onKeyboard)
            controlDivider
            controlButton("power", label: "锁屏", action: onPower)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button(action: onRotate) {
                Label("旋转屏幕", systemImage: "rotate.right")
            }
            Button(action: onVolumeDown) {
                Label("降低音量", systemImage: "speaker.minus.fill")
            }
            Button(action: onVolumeUp) {
                Label("提高音量", systemImage: "speaker.plus.fill")
            }
        } label: {
            controlLabel("ellipsis", label: "更多")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("更多控制")
    }

    private var controlDivider: some View {
        Divider()
            .frame(height: 50)
            .overlay(.white.opacity(0.1))
    }

    private func controlButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            controlLabel(symbol, label: label)
        }
        .accessibilityLabel(label)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func controlLabel(
        _ symbol: String,
        label: String
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(height: 24)
            Text(label)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
    }
}

struct CollapsedControlHandle: View {
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            Image(systemName: "chevron.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 26)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(0.85)
        .accessibilityLabel("显示控制栏")
    }
}
