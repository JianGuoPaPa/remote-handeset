import Foundation

struct ConnectionDiagnostics: Equatable {
    var network = NetworkMonitor.Interface.unavailable.rawValue
    var route = "TURN 中继"
    var localCandidateType: String?
    var remoteCandidateType: String?
    var transportProtocol: String?
    var relayProtocol: String?
    var gatewayRoute: String?
    var gatewayLocalCandidateType: String?
    var gatewayRemoteCandidateType: String?
    var gatewayTransportProtocol: String?
    var gatewayRelayProtocol: String?
    var gatewayRoundTripMilliseconds: Double?
    var gatewayAgentState: String?
    var controlProtocol = "协商中"
    var streamProfile = RemoteStreamProfile.standard.displayName
    var roundTripMilliseconds: Double?
    var jitterMilliseconds: Double?
    var jitterBufferDelayMilliseconds: Double?
    var receivedFramesPerSecond: Double?
    var receivedBitrateKbps: Double?
    var packetLossPercent: Double?
    var resolution: String?
    var framesDropped: Int64?
    var framesDecoded: Int64?
    var candidatePairState: String?
    var controlAcknowledgementRoundTripMilliseconds: Double?
    var gatewayDriverWriteMilliseconds: Double?
    var nextFrameFeedbackRoundTripMilliseconds: Double?
    var gatewayNextFrameAfterWriteMilliseconds: Double?
    var decodedFrameConfirmationRoundTripMilliseconds: Double?
    var lastControlAcknowledgementSucceeded: Bool?
    var lastControlAcknowledgementStatus: String?
    var microphoneInputState: String?
    var microphoneDemandGeneration: UInt64?
    var microphonePacketsSent: Int64?
    var microphoneBytesSent: Int64?
    var microphoneLastError: String?
    var lastUpdated: Date?

    static let empty = ConnectionDiagnostics()
}
