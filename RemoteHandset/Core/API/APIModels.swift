import Foundation

struct ChallengeResponse: Decodable {
    let csrf: String
}

struct LoginResponse: Decodable {
    let ok: Bool
}

struct SessionResponse: Decodable {
    let authenticated: Bool
    let csrf: String?
}

struct GatewaySessionResponse: Decodable {
    let websocketUrl: String
}

struct IceConfigurationResponse: Decodable {
    let expiresAt: Int?
    let iceServers: [IceServerPayload]
}

struct IceServerPayload: Decodable {
    let urls: [String]
    let username: String?
    let credential: String?

    private enum CodingKeys: String, CodingKey {
        case urls
        case username
        case credential
    }

    init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let values = try? container.decode([String].self, forKey: .urls) {
            urls = values
        } else {
            urls = [try container.decode(String.self, forKey: .urls)]
        }
        username = try container.decodeIfPresent(String.self, forKey: .username)
        credential = try container.decodeIfPresent(String.self, forKey: .credential)
    }
}

struct GatewaySignal: Decodable {
    let status: String
    let stage: String?
    let message: String?
    let sdp: String?
    let capabilities: RemoteCapabilities?
    let mediaMeta: RemoteMediaMetadata?
    let controlProtocolVersion: Int?

    private enum CodingKeys: String, CodingKey {
        case status
        case stage
        case message
        case sdp
        case capabilities
        case mediaMeta = "media_meta"
        case controlProtocolVersion = "control_protocol_version"
    }
}

struct RemoteCapabilities: Decodable, Equatable {
    let canClipboard: Bool?
    let canUHID: Bool?
    let canVideo: Bool?
    let canAudio: Bool?
    let canControl: Bool?
    let canMicrophoneInput: Bool?
    let isAndroid: Bool?

    private enum CodingKeys: String, CodingKey {
        case canClipboard = "can_clipboard"
        case canUHID = "can_uhid"
        case canVideo = "can_video"
        case canAudio = "can_audio"
        case canControl = "can_control"
        case canMicrophoneInput = "can_microphone_input"
        case isAndroid = "is_android"
    }
}

struct RemoteMediaMetadata: Decodable, Equatable {
    let videoCodec: String?
    let width: Int?
    let height: Int?
    let fps: Int?
    let audioCodec: String?

    private enum CodingKeys: String, CodingKey {
        case videoCodec = "video_codec"
        case width
        case height
        case fps
        case audioCodec = "audio_codec"
    }
}

struct GatewayRouteTelemetry: Decodable {
    let event: String
    let route: String?
    let localCandidateType: String?
    let remoteCandidateType: String?
    let `protocol`: String?
    let relayProtocol: String?
    let rttMs: Double?
    let streamProfile: String?
    let generation: UInt64?
    let agentGeneration: UInt64?
    let error: String?
}

struct APIErrorPayload: Decodable {
    let error: String?
    let message: String?
}

/// The phone-to-Mac connection, independent of the iPhone's WebRTC route.
struct DeviceConnectionStatus: Decodable, Equatable {
    let deviceID: String
    let wirelessConfigured: Bool
    let usbAvailable: Bool
    let wifiAvailable: Bool
    let preference: String
    let activeTransport: String
    let state: String
    let generation: UInt64
    let instanceID: String?
    let lastError: String?

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case wirelessConfigured = "wireless_configured"
        case usbAvailable = "usb_available"
        case wifiAvailable = "wifi_available"
        case preference
        case activeTransport = "active_transport"
        case state, generation
        case instanceID = "instance_id"
        case lastError = "last_error"
    }

    var isSwitching: Bool { state == "switching" }
    var usesWirelessPreference: Bool { preference == "wifi" }
    func canReplace(
        _ current: Self?, requestSequence: UInt64, lastAcceptedRequestSequence: UInt64
    ) -> Bool {
        guard let current else { return true }
        guard deviceID == current.deviceID else { return false }
        if instanceID == current.instanceID {
            return generation > current.generation
                || (generation == current.generation && requestSequence >= lastAcceptedRequestSequence)
        }
        // Gateway restarts reset generation. The local request order prevents
        // a delayed response from the old process restoring stale state.
        return requestSequence >= lastAcceptedRequestSequence
    }
    var transportLabel: String {
        if isSwitching { return "正在切换" }
        switch activeTransport {
        case "usb": return "有线连接"
        case "wifi": return "无线连接"
        default: return "尚未连接"
        }
    }
}

struct DeviceConnectionResponse: Decodable {
    let type: String
    let requestID: String
    let status: String
    let message: String?
    let connection: DeviceConnectionStatus?

    private enum CodingKeys: String, CodingKey {
        case type, status, message, connection
        case requestID = "request_id"
    }

    func validated(requestID: String, deviceID: String) throws -> Self {
        guard type == "transport_status", self.requestID == requestID,
              status == "ok" || status == "error",
              connection == nil || connection?.deviceID == deviceID else {
            throw PortalError.malformedPayload
        }
        return self
    }
}

enum PortalError: LocalizedError {
    case invalidServerAddress
    case untrustedGatewayAddress
    case invalidResponse
    case unauthorized
    case rateLimited
    case server(statusCode: Int, message: String?)
    case malformedPayload

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            return "服务器地址无效"
        case .untrustedGatewayAddress:
            return "服务器返回了不可信的连接地址"
        case .invalidResponse:
            return "服务器没有返回有效响应"
        case .unauthorized:
            return "密码不正确或登录已过期"
        case .rateLimited:
            return "尝试次数过多，请稍后再试"
        case let .server(_, message):
            return message ?? "服务器暂时不可用"
        case .malformedPayload:
            return "服务器返回的数据格式不正确"
        }
    }
}
