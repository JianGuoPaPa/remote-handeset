import AppKit
import OSLog

/// A momentary button with explicit press/release callbacks. Cancellation,
/// window removal, or disabling always emits release so microphone injection
/// cannot remain active after the user stops holding the control.
final class PushToTalkButton: NSButton {
    enum CancelReason: String {
        case applicationResigned
        case controlDisconnected
        case controlError
        case externalCancellation
    }

    private enum ReleaseReason: String {
        case mouseTrackingEnded
        case keyUp
        case disabled
        case viewRemoved
        case focusLost
        case applicationResigned
        case controlDisconnected
        case controlError
        case externalCancellation
    }

    private static let logger = Logger(
        subsystem: "local.iphone.usbconsole",
        category: "PushToTalk"
    )

    var onPressChanged: ((Bool) -> Void)?

    private var pressed = false
    private var activeGeneration: UInt64 = 0
    private var keyboardGeneration: UInt64?
    private var pressStartedAtNanoseconds: UInt64?

    override var isEnabled: Bool {
        didSet {
            if oldValue && !isEnabled {
                releaseIfNeeded(reason: .disabled)
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureButton()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { releaseIfNeeded(reason: .viewRemoved) }
        super.viewWillMove(toWindow: newWindow)
    }

    /// NSButton's native tracking loop stays active until the matching mouse-up
    /// (or AppKit cancels tracking). Starting before that loop and releasing in
    /// `defer` preserves the full physical hold duration without competing
    /// gesture recognizers ending the press early.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            super.mouseDown(with: event)
            return
        }

        guard let generation = beginPress() else { return }
        defer {
            releaseIfNeeded(
                reason: .mouseTrackingEnded,
                expectedGeneration: generation
            )
        }
        super.mouseDown(with: event)
    }

    /// Preserve hold-to-talk semantics for keyboard users when the button has
    /// focus. Key repeat must not create additional begin events.
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 49 else {
            super.keyDown(with: event)
            return
        }
        guard isEnabled else { return }
        if !event.isARepeat {
            keyboardGeneration = beginPress()
        }
    }

    override func keyUp(with event: NSEvent) {
        guard event.keyCode == 49 else {
            super.keyUp(with: event)
            return
        }
        guard let generation = keyboardGeneration else { return }
        keyboardGeneration = nil
        releaseIfNeeded(reason: .keyUp, expectedGeneration: generation)
    }

    override func resignFirstResponder() -> Bool {
        releaseIfNeeded(reason: .focusLost)
        return super.resignFirstResponder()
    }

    func cancelPress(reason: CancelReason = .externalCancellation) {
        let internalReason: ReleaseReason
        switch reason {
        case .applicationResigned:
            internalReason = .applicationResigned
        case .controlDisconnected:
            internalReason = .controlDisconnected
        case .controlError:
            internalReason = .controlError
        case .externalCancellation:
            internalReason = .externalCancellation
        }
        releaseIfNeeded(reason: internalReason)
    }

    private func configureButton() {
        setButtonType(.momentaryPushIn)
    }

    @discardableResult
    private func beginPress() -> UInt64? {
        guard isEnabled, !pressed else { return nil }
        activeGeneration &+= 1
        if activeGeneration == 0 { activeGeneration = 1 }
        pressed = true
        pressStartedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        state = .on
        Self.logger.info("Push-to-talk began generation=\(self.activeGeneration, privacy: .public)")
        onPressChanged?(true)
        return activeGeneration
    }

    private func releaseIfNeeded(
        reason: ReleaseReason,
        expectedGeneration: UInt64? = nil
    ) {
        guard pressed else { return }
        if let expectedGeneration, expectedGeneration != activeGeneration {
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let durationMilliseconds = pressStartedAtNanoseconds.map {
            now >= $0 ? (now - $0) / 1_000_000 : 0
        } ?? 0
        let completedGeneration = activeGeneration
        pressed = false
        keyboardGeneration = nil
        pressStartedAtNanoseconds = nil
        state = .off
        Self.logger.info(
            "Push-to-talk ended generation=\(completedGeneration, privacy: .public) reason=\(reason.rawValue, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)"
        )
        onPressChanged?(false)
    }
}
