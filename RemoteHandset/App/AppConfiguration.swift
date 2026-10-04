import Foundation

enum RemoteDeviceType: String, Codable, Sendable {
    case android
    case iPhoneUSB = "iphone-usb"
}

struct DeviceTarget: Hashable, Codable, Sendable, Identifiable {
    let id: String
    let type: RemoteDeviceType
    let displayName: String

    var supportsMicrophoneInjection: Bool {
        type == .iPhoneUSB
    }

    var supportsAndroidNavigation: Bool {
        type == .android
    }
}

enum AppConfiguration {
    static let defaultServerURL = URL(string: "https://70.39.202.192")!
    static let defaultServerString = defaultServerURL.absoluteString

    // The calculator has one unlock password. Device identity and transport
    // details stay in this local list and are never rendered on the calculator
    // surface.
    static let calculatorPassword = "CHANGE_ME_ON_NEW_SITE"

    static let deviceTargets: [DeviceTarget] = [
        DeviceTarget(
            id: "ZY22GHBP48",
            type: .android,
            displayName: "Motorola"
        ),
        DeviceTarget(
            id: "ZY22K2SXMK",
            type: .android,
            displayName: "Motorola 2"
        ),
        DeviceTarget(
            id: "ZY22F68DH8",
            type: .android,
            displayName: "白摩托"
        ),
        DeviceTarget(
            id: "31629594940010K",
            type: .android,
            displayName: "备用机1"
        ),
        DeviceTarget(
            id: "ZY22GDWXSZ",
            type: .android,
            displayName: "备用机2"
        ),
        DeviceTarget(
            id: "ZY22HN3ZS4",
            type: .android,
            displayName: "备用机3"
        ),
        DeviceTarget(
            id: "10AD6F2LSY0017B",
            type: .android,
            displayName: "vivo V2248"
        ),
        DeviceTarget(
            id: "iphone11-usb",
            type: .iPhoneUSB,
            displayName: "苹果11"
        )
    ]

    static let defaultDeviceTarget = deviceTargets[0]

    static func deviceTarget(id: String) -> DeviceTarget? {
        deviceTargets.first { $0.id == id }
    }

    // Single portal password the gateway accepts. It is independent from the
    // calculator unlock password above.
    static let portalPassword = "CHANGE_ME_ON_NEW_SITE"

    static let preferredVideoSize = 1280
    static let transientChannelHighWaterMark: UInt64 = 256

    // Starting stream profile. Kept modest because the primary link is a
    // cross-border relay (China ↔ Hong Kong ↔ Thailand) where too high a
    // bitrate mainly buys packet loss, retransmits and growing latency. The
    // adaptive policy still upshifts toward `.standard` once the link proves
    // healthy, and downshifts to `.low` when it does not.
    static let defaultStreamProfile: RemoteStreamProfile = .constrained

    // Keyframe (I-frame) interval in seconds pushed to the gateway encoder.
    // The gateway already forces a fresh keyframe on RTCP PLI (with a cached
    // keyframe inside a 2s window), so a longer GOP is safe and avoids the
    // per-second keyframe bandwidth spikes that cause periodic stutter on a
    // marginal WAN link.
    static let videoKeyframeIntervalSeconds = 4

    static let signalingHeartbeatInterval: TimeInterval = 15
    static let signalingHeartbeatTimeout: TimeInterval = 8
    static let signalingHeartbeatFailureLimit = 3
    static let peerDisconnectGracePeriod: Duration = .seconds(12)
    static let connectionTotalTimeout: Duration = .seconds(55)
    static let portalStageTimeout: Duration = .seconds(25)
    static let iceGatheringStageTimeout: Duration = .seconds(20)
    static let websocketStageTimeout: Duration = .seconds(20)
    static let answerStageTimeout: Duration = .seconds(15)
    static let peerStageTimeout: Duration = .seconds(15)
    static let mediaStageTimeout: Duration = .seconds(20)
    static let rotationMetadataTimeout: Duration = .seconds(5)
    static let candidateConnectionTimeout: Duration = .seconds(90)

    static let serverDefaultsKey = "remote.serverURL"
    static let rememberPasswordDefaultsKey = "remote.rememberPassword"
    static let keychainService = "com.dltengwen.remotehandset.credentials"
    static let keychainPasswordAccount = "portal-password"
}
