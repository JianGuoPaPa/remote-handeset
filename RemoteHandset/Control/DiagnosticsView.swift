import SwiftUI

struct DiagnosticsView: View {
    let diagnostics: ConnectionDiagnostics
    let gatewayMessage: String?
    let onReconnect: () -> Void
    let onLogout: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("连接") {
                    row("网络", diagnostics.network)
                    row("路径", diagnostics.route)
                    row("App 候选", appCandidateDescription)
                    row("App 传输", appTransportDescription)
                    row("往返延迟", format(diagnostics.roundTripMilliseconds, suffix: " ms", digits: 0))
                    row("抖动", format(diagnostics.jitterMilliseconds, suffix: " ms", digits: 1))
                    row("丢包", format(diagnostics.packetLossPercent, suffix: "%", digits: 2))
                    row("网关路径", diagnostics.gatewayRoute ?? "—")
                    row(
                        "网关候选",
                        gatewayCandidateDescription
                    )
                    row(
                        "网关传输",
                        gatewayTransportDescription
                    )
                    row(
                        "网关往返延迟",
                        format(
                            diagnostics.gatewayRoundTripMilliseconds,
                            suffix: " ms",
                            digits: 0
                        )
                    )
                    row("路径交叉确认", routeAgreementDescription)
                    row("远端编码器", diagnostics.gatewayAgentState ?? "—")
                }

                Section("画面") {
                    row("画质档位", diagnostics.streamProfile)
                    row("分辨率", diagnostics.resolution ?? "—")
                    row("接收帧率", format(diagnostics.receivedFramesPerSecond, suffix: " fps", digits: 1))
                    row("接收码率", format(diagnostics.receivedBitrateKbps, suffix: " kbps", digits: 0))
                    row("接收缓冲", format(diagnostics.jitterBufferDelayMilliseconds, suffix: " ms", digits: 0))
                    row("已解码帧", diagnostics.framesDecoded.map(String.init) ?? "—")
                    row("丢弃帧", diagnostics.framesDropped.map(String.init) ?? "—")
                }

                Section("操作") {
                    row("控制协议", diagnostics.controlProtocol)
                    row(
                        "指令确认往返",
                        format(
                            diagnostics.controlAcknowledgementRoundTripMilliseconds,
                            suffix: " ms",
                            digits: 0
                        )
                    )
                    row(
                        "网关写入设备",
                        format(
                            diagnostics.gatewayDriverWriteMilliseconds,
                            suffix: " ms",
                            digits: 1
                        )
                    )
                    row(
                        "下一编码帧反馈",
                        format(
                            diagnostics.nextFrameFeedbackRoundTripMilliseconds,
                            suffix: " ms",
                            digits: 0
                        )
                    )
                    row(
                        "设备写入到下一帧",
                        format(
                            diagnostics.gatewayNextFrameAfterWriteMilliseconds,
                            suffix: " ms",
                            digits: 0
                        )
                    )
                    row(
                        "反馈后下一解码帧",
                        format(
                            diagnostics.decodedFrameConfirmationRoundTripMilliseconds,
                            suffix: " ms",
                            digits: 0
                        )
                    )
                    row(
                        "最近指令",
                        diagnostics.lastControlAcknowledgementStatus ?? "—"
                    )
                }

                if diagnostics.microphoneInputState != nil {
                    Section("音频输入") {
                        row("状态", diagnostics.microphoneInputState ?? "—")
                        row(
                            "会话",
                            diagnostics.microphoneDemandGeneration.map(String.init) ?? "—"
                        )
                        row(
                            "发送包",
                            diagnostics.microphonePacketsSent.map(String.init) ?? "—"
                        )
                        row(
                            "发送字节",
                            diagnostics.microphoneBytesSent.map(String.init) ?? "—"
                        )
                        if let error = diagnostics.microphoneLastError {
                            row("最近异常", error)
                        }
                    }
                }

                if let gatewayMessage, !gatewayMessage.isEmpty {
                    Section("网关") {
                        Text(gatewayMessage)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Button("重新连接", action: onReconnect)
                    Button("退出登录", role: .destructive, action: onLogout)
                }
            }
            .navigationTitle("连接诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func format(_ value: Double?, suffix: String, digits: Int) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(digits)f%@", value, suffix)
    }

    private var gatewayCandidateDescription: String {
        let local = diagnostics.gatewayLocalCandidateType
        let remote = diagnostics.gatewayRemoteCandidateType
        guard local != nil || remote != nil else { return "—" }
        return "\(local ?? "—") / \(remote ?? "—")"
    }

    private var appCandidateDescription: String {
        let local = diagnostics.localCandidateType
        let remote = diagnostics.remoteCandidateType
        guard local != nil || remote != nil else { return "—" }
        return "\(local ?? "—") / \(remote ?? "—")"
    }

    private var appTransportDescription: String {
        let transport = diagnostics.transportProtocol
        let relay = diagnostics.relayProtocol
        guard transport != nil || relay != nil else { return "—" }
        if let relay, !relay.isEmpty {
            return "\(transport ?? "—") / \(relay)"
        }
        return transport ?? "—"
    }

    private var gatewayTransportDescription: String {
        let transport = diagnostics.gatewayTransportProtocol
        let relay = diagnostics.gatewayRelayProtocol
        guard transport != nil || relay != nil else { return "—" }
        if let relay, !relay.isEmpty {
            return "\(transport ?? "—") / \(relay)"
        }
        return transport ?? "—"
    }

    private var routeAgreementDescription: String {
        let appTypes = [
            diagnostics.localCandidateType,
            diagnostics.remoteCandidateType
        ].compactMap { $0?.lowercased() }
        let gatewayTypes = [
            diagnostics.gatewayLocalCandidateType,
            diagnostics.gatewayRemoteCandidateType
        ].compactMap { $0?.lowercased() }
        guard !appTypes.isEmpty,
              !gatewayTypes.isEmpty || diagnostics.gatewayRoute != nil
        else {
            return "等待数据"
        }

        let appUsesRelay = appTypes.contains("relay")
        let gatewayUsesRelay = gatewayTypes.contains("relay")
            || diagnostics.gatewayRoute?.lowercased().contains("relay") == true
        return appUsesRelay == gatewayUsesRelay ? "一致" : "不一致"
    }
}
