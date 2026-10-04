import Foundation

@MainActor
final class ConsoleStatusWriter {
    private let fileURL: URL
    private let deviceID: String
    private let displayName: String

    private var usbConnected = false
    private var captureRunning = false
    private var rfbConnected = false
    private var webRunning = false
    private var driverRunning = false
    private var videoSocketRunning = false
    private var audioSocketRunning = false
    private var controlSocketRunning = false
    private var videoFrameAgeMilliseconds: Double?
    private var audioRunning = false
    private var microphoneBridgeState = "idle"
    private var lastError = ""

    init(fileURL: URL, deviceID: String, displayName: String) {
        self.fileURL = fileURL
        self.deviceID = deviceID
        self.displayName = displayName
        write()
    }

    func updateUSBConnected(_ value: Bool) {
        usbConnected = value
        write()
    }

    func updateCapture(running: Bool, frameAgeMilliseconds: Double?) {
        captureRunning = running
        if let value = frameAgeMilliseconds, value.isFinite, value >= 0 {
            videoFrameAgeMilliseconds = value
        } else if !running {
            videoFrameAgeMilliseconds = nil
        }
        write()
    }

    func updateRFBConnected(_ value: Bool) {
        rfbConnected = value
        write()
    }

    func updateWebRunning(_ value: Bool) {
        webRunning = value
        write()
    }

    func updateDriverRunning(_ value: Bool) {
        driverRunning = value
        write()
    }

    func updateMediaSockets(video: Bool, audio: Bool, control: Bool) {
        videoSocketRunning = video
        audioSocketRunning = audio
        controlSocketRunning = control
        write()
    }

    func updateAudioRunning(_ value: Bool) {
        audioRunning = value
        write()
    }

    func updateMicrophoneBridgeState(_ value: String) {
        microphoneBridgeState = Self.sanitize(value, maximumLength: 64)
        write()
    }

    func updateError(_ value: String?) {
        lastError = Self.sanitize(value ?? "", maximumLength: 240)
        write()
    }

    func heartbeat() {
        write()
    }

    private func write() {
        let frameAge = videoFrameAgeMilliseconds.map { String(format: "%.1f", $0) } ?? "-1"
        let lines = [
            "timestamp=\(Int(Date().timeIntervalSince1970))",
            "device_id=\(deviceID)",
            "display_name=\(displayName)",
            "usb_connected=\(usbConnected ? 1 : 0)",
            "capture_running=\(captureRunning ? 1 : 0)",
            "rfb_connected=\(rfbConnected ? 1 : 0)",
            "web_running=\(webRunning ? 1 : 0)",
            "driver_running=\(driverRunning ? 1 : 0)",
            "video_socket_running=\(videoSocketRunning ? 1 : 0)",
            "audio_socket_running=\(audioSocketRunning ? 1 : 0)",
            "control_socket_running=\(controlSocketRunning ? 1 : 0)",
            "video_frame_age_ms=\(frameAge)",
            "audio_running=\(audioRunning ? 1 : 0)",
            "microphone_bridge_state=\(microphoneBridgeState)",
            "last_error=\(lastError)"
        ]
        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // Status reporting must never interrupt capture or control.
        }
    }

    private static func sanitize(_ value: String, maximumLength: Int) -> String {
        let oneLine = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "=", with: ":")
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(oneLine).prefix(maximumLength))
    }
}
