import Foundation

struct VideoEncoderConfiguration: Equatable, Sendable {
    let averageBitRate: Int
    let expectedFrameRate: Int
    let keyFrameIntervalSeconds: Double
    let maximumDimension: Int

    static let productionDefault = VideoEncoderConfiguration(
        averageBitRate: 1_400_000,
        expectedFrameRate: 30,
        keyFrameIntervalSeconds: 4,
        maximumDimension: 1_280
    )
}

struct ConsoleConfiguration: Equatable, Sendable {
    static let defaultDeviceID = "iphone11-usb"
    static let defaultDisplayName = "苹果11"
    static let defaultTargetUDID = "00008030-001E10691152802E"

    let deviceID: String
    let displayName: String
    let targetUDID: String
    let captureDeviceUniqueID: String?
    let encoder: VideoEncoderConfiguration
    let audioBitRate: Int
    let launchInBackground: Bool
    let stateDirectoryURL: URL

    var statusFileURL: URL { stateDirectoryURL.appendingPathComponent("status") }
    var bridgeTokenFileURL: URL { stateDirectoryURL.appendingPathComponent("bridge-token") }
    var videoSocketURL: URL { stateDirectoryURL.appendingPathComponent("video.sock") }
    var audioSocketURL: URL { stateDirectoryURL.appendingPathComponent("audio.sock") }
    var controlSocketURL: URL { stateDirectoryURL.appendingPathComponent("control.sock") }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> ConsoleConfiguration {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let stateDirectory = environment["IUSC_STATE_DIRECTORY"].flatMap { value -> URL? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        } ?? homeDirectory
            .appendingPathComponent(".remote-handset", isDirectory: true)
            .appendingPathComponent("iphone-console", isDirectory: true)

        let configuredBitRate = environment["IUSC_VIDEO_BITRATE"].flatMap(Int.init)
        let configuredFPS = environment["IUSC_VIDEO_FPS"].flatMap(Int.init)
        let configuredGOP = environment["IUSC_VIDEO_GOP_SECONDS"].flatMap(Double.init)
        let configuredMaximumDimension = environment["IUSC_VIDEO_MAX_SIZE"].flatMap(Int.init)
        let configuredAudioBitRate = environment["IUSC_AUDIO_BITRATE"].flatMap(Int.init)
        let encoder = VideoEncoderConfiguration(
            averageBitRate: min(max(configuredBitRate ?? 1_400_000, 256_000), 20_000_000),
            expectedFrameRate: min(max(configuredFPS ?? 30, 5), 60),
            keyFrameIntervalSeconds: min(max(configuredGOP ?? 4, 0.5), 10),
            maximumDimension: min(max(configuredMaximumDimension ?? 1_280, 480), 4_096)
        )

        return ConsoleConfiguration(
            deviceID: normalizedIdentifier(
                environment["IUSC_DEVICE_ID"],
                fallback: defaultDeviceID
            ),
            displayName: normalizedDisplayName(
                environment["IUSC_DISPLAY_NAME"],
                fallback: defaultDisplayName
            ),
            targetUDID: normalizedUDID(
                environment["IUSC_TARGET_UDID"],
                fallback: defaultTargetUDID
            ),
            captureDeviceUniqueID: normalizedOptional(environment["IUSC_CAPTURE_DEVICE_UNIQUE_ID"]),
            encoder: encoder,
            audioBitRate: min(max(configuredAudioBitRate ?? 64_000, 32_000), 128_000),
            launchInBackground: arguments.contains("--background"),
            stateDirectoryURL: stateDirectory
        )
    }

    private static func normalizedIdentifier(_ value: String?, fallback: String) -> String {
        guard let value = normalizedOptional(value), value.count <= 64,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return fallback }
        return value
    }

    private static func normalizedDisplayName(_ value: String?, fallback: String) -> String {
        guard let value = normalizedOptional(value), value.count <= 64,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return fallback }
        return value
    }

    private static func normalizedUDID(_ value: String?, fallback: String) -> String {
        guard let value = normalizedOptional(value), (24...64).contains(value.count),
              value.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "-") })
        else { return fallback }
        return value.uppercased()
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
