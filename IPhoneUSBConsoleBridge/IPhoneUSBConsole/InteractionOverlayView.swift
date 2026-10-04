import AppKit

@MainActor
protocol InteractionOverlayViewDelegate: AnyObject {
    func interactionOverlayView(
        _ view: InteractionOverlayView,
        sendPointerMask mask: UInt8,
        x: UInt16,
        y: UInt16
    )

    func interactionOverlayView(
        _ view: InteractionOverlayView,
        sendKeyDown down: Bool,
        keysym: UInt32
    )

    func interactionOverlayViewDidRequestReleaseAllInputs(_ view: InteractionOverlayView)
}

/// Transparent input surface placed directly above `VideoPreviewView`.
///
/// `videoRect` must use this view's local, top-left-origin coordinate system.
/// Pointer events outside that rectangle are ignored unless an active gesture
/// needs to be released, in which case its final point is clamped to the video.
final class InteractionOverlayView: NSView {
    weak var delegate: InteractionOverlayViewDelegate?

    var videoRect: CGRect = .zero
    var framebufferSize: CGSize = .zero

    var controlEnabled = false {
        didSet {
            guard controlEnabled != oldValue else { return }
            if !controlEnabled {
                releaseAllInputs()
                if window?.firstResponder === self {
                    window?.makeFirstResponder(nil)
                }
            }
        }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { controlEnabled }
    override var mouseDownCanMoveWindow: Bool { false }

    private enum PointerButton {
        static let left: UInt8 = 1
        static let middle: UInt8 = 2 // TrollVNC: Power
        static let right: UInt8 = 4  // TrollVNC: Home/Menu
        static let wheelUp: UInt8 = 8
        static let wheelDown: UInt8 = 16
    }

    private enum KeySym {
        static let backspace: UInt32 = 0xFF08
        static let tab: UInt32 = 0xFF09
        static let returnKey: UInt32 = 0xFF0D
        static let escape: UInt32 = 0xFF1B
        static let home: UInt32 = 0xFF50
        static let left: UInt32 = 0xFF51
        static let up: UInt32 = 0xFF52
        static let right: UInt32 = 0xFF53
        static let down: UInt32 = 0xFF54
        static let pageUp: UInt32 = 0xFF55
        static let pageDown: UInt32 = 0xFF56
        static let end: UInt32 = 0xFF57
        static let insert: UInt32 = 0xFF63
        static let keypadEnter: UInt32 = 0xFF8D
        static let delete: UInt32 = 0xFFFF

        static let shiftLeft: UInt32 = 0xFFE1
        static let shiftRight: UInt32 = 0xFFE2
        static let controlLeft: UInt32 = 0xFFE3
        static let controlRight: UInt32 = 0xFFE4
        static let metaLeft: UInt32 = 0xFFE7
        static let metaRight: UInt32 = 0xFFE8
        static let altLeft: UInt32 = 0xFFE9
        static let altRight: UInt32 = 0xFFEA

        static let function1: UInt32 = 0xFFBE
    }

    private static let dragInterval = 1.0 / 60.0
    private static let preciseWheelStep: CGFloat = 8.0
    private static let maxWheelPulsesPerEvent = 8

    private var activePointerMask: UInt8 = 0
    private var lastPointerPoint: (x: UInt16, y: UInt16)?
    private var lastDragTimestamp = -Double.infinity
    private var wheelAccumulator: CGFloat = 0

    private var pressedKeysymsByKeyCode: [UInt16: UInt32] = [:]
    private var activeModifierKeysyms: Set<UInt32> = []

    private var applicationResignObserver: NSObjectProtocol?
    private var windowResignObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    deinit {
        if let applicationResignObserver {
            NotificationCenter.default.removeObserver(applicationResignObserver)
        }
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
        }
    }

    private func configureView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        applicationResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.releaseAllInputs()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, window !== newWindow {
            releaseAllInputs()
        }
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.releaseAllInputs()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard controlEnabled, !isHidden, alphaValue > 0, bounds.contains(point) else {
            return nil
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        controlEnabled
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            releaseAllInputs()
        }
        return resigned
    }

    // MARK: - Pointer input

    override func mouseDown(with event: NSEvent) {
        handleButtonDown(PointerButton.left, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        handleButtonUp(PointerButton.left, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        handleDrag(event, requiredButton: PointerButton.left)
    }

    override func rightMouseDown(with event: NSEvent) {
        handleButtonDown(PointerButton.right, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        handleButtonUp(PointerButton.right, event: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleDrag(event, requiredButton: PointerButton.right)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        handleButtonDown(PointerButton.middle, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        handleButtonUp(PointerButton.middle, event: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDragged(with: event)
            return
        }
        handleDrag(event, requiredButton: PointerButton.middle)
    }

    override func scrollWheel(with event: NSEvent) {
        guard controlEnabled,
              let point = mappedPoint(for: event, clampToVideo: false),
              event.scrollingDeltaY != 0 else {
            if !controlEnabled {
                super.scrollWheel(with: event)
            }
            return
        }

        lastPointerPoint = point
        wheelAccumulator += event.scrollingDeltaY
        let step = event.hasPreciseScrollingDeltas ? Self.preciseWheelStep : 1.0
        var pulses = 0

        while abs(wheelAccumulator) >= step, pulses < Self.maxWheelPulsesPerEvent {
            let wheelMask = wheelAccumulator > 0 ? PointerButton.wheelUp : PointerButton.wheelDown
            sendPointer(mask: activePointerMask | wheelMask, point: point)
            sendPointer(mask: activePointerMask, point: point)
            wheelAccumulator += wheelAccumulator > 0 ? -step : step
            pulses += 1
        }

        if event.phase.contains(.ended) ||
            event.phase.contains(.cancelled) ||
            event.momentumPhase.contains(.ended) {
            wheelAccumulator = 0
        }
    }

    private func handleButtonDown(_ button: UInt8, event: NSEvent) {
        guard controlEnabled,
              activePointerMask & button == 0,
              let point = mappedPoint(for: event, clampToVideo: false) else {
            return
        }

        window?.makeFirstResponder(self)
        activePointerMask |= button
        lastPointerPoint = point
        lastDragTimestamp = -Double.infinity
        sendPointer(mask: activePointerMask, point: point)
    }

    private func handleButtonUp(_ button: UInt8, event: NSEvent) {
        guard controlEnabled, activePointerMask & button != 0 else { return }

        let point = mappedPoint(for: event, clampToVideo: true) ?? lastPointerPoint
        if let point {
            // AppKit can coalesce a very fast mouse drag into down/up with no
            // intervening `mouseDragged` callback. TrollVNC interprets the
            // release as a lift, not as a move, so explicitly deliver the final
            // pressed coordinate before clearing the button. This also closes
            // the normal 60 Hz throttle window and guarantees the gesture's
            // last position reaches the device.
            if lastPointerPoint?.x != point.x || lastPointerPoint?.y != point.y {
                sendPointer(mask: activePointerMask, point: point)
            }
            activePointerMask &= ~button
            lastPointerPoint = point
            sendPointer(mask: activePointerMask, point: point)
        } else {
            // A framebuffer/layout transition invalidated the mapping mid-gesture.
            // Clear every local bit together with the delegate's wire state so a
            // later drag cannot accidentally re-assert a stale touch.
            releaseAllInputs()
        }
        lastDragTimestamp = -Double.infinity
    }

    private func handleDrag(_ event: NSEvent, requiredButton: UInt8) {
        guard controlEnabled, activePointerMask & requiredButton != 0 else { return }

        let timestamp = event.timestamp
        if timestamp >= lastDragTimestamp,
           timestamp - lastDragTimestamp < Self.dragInterval {
            return
        }

        guard let point = mappedPoint(for: event, clampToVideo: true) else { return }
        lastDragTimestamp = timestamp
        lastPointerPoint = point
        sendPointer(mask: activePointerMask, point: point)
    }

    private func sendPointer(mask: UInt8, point: (x: UInt16, y: UInt16)) {
        delegate?.interactionOverlayView(self, sendPointerMask: mask, x: point.x, y: point.y)
    }

    private func mappedPoint(for event: NSEvent, clampToVideo: Bool) -> (x: UInt16, y: UInt16)? {
        let localPoint = convert(event.locationInWindow, from: nil)
        return mappedPoint(localPoint, clampToVideo: clampToVideo)
    }

    private func mappedPoint(_ localPoint: CGPoint, clampToVideo: Bool) -> (x: UInt16, y: UInt16)? {
        let rect = videoRect.standardized

        guard rect.width > 0,
              rect.height > 0,
              rect.minX.isFinite,
              rect.minY.isFinite,
              rect.maxX.isFinite,
              rect.maxY.isFinite,
              framebufferSize.width.isFinite,
              framebufferSize.height.isFinite,
              framebufferSize.width >= 1,
              framebufferSize.height >= 1,
              localPoint.x.isFinite,
              localPoint.y.isFinite else {
            return nil
        }

        // RFB pointer coordinates are 16-bit. Capping before converting to Int
        // also makes malformed or transiently huge layout values non-trapping.
        let framebufferWidth = Int(min(framebufferSize.width.rounded(.down), CGFloat(UInt16.max)))
        let framebufferHeight = Int(min(framebufferSize.height.rounded(.down), CGFloat(UInt16.max)))

        var point = localPoint
        if clampToVideo {
            point.x = min(max(point.x, rect.minX), rect.maxX)
            point.y = min(max(point.y, rect.minY), rect.maxY)
        } else if !rect.contains(point) {
            return nil
        }

        let normalizedX = (point.x - rect.minX) / rect.width
        let normalizedY = (point.y - rect.minY) / rect.height
        let x = min(max(Int(floor(normalizedX * CGFloat(framebufferWidth))), 0), framebufferWidth - 1)
        let y = min(max(Int(floor(normalizedY * CGFloat(framebufferHeight))), 0), framebufferHeight - 1)

        return (
            UInt16(clamping: min(x, Int(UInt16.max))),
            UInt16(clamping: min(y, Int(UInt16.max)))
        )
    }

    // MARK: - Keyboard input

    override func flagsChanged(with event: NSEvent) {
        guard controlEnabled else {
            if !controlEnabled {
                super.flagsChanged(with: event)
            }
            return
        }

        // AppKit exposes Shift/Control/Option/Command as aggregate flags. Treat
        // each pair as one logical modifier so releasing left Shift while right
        // Shift remains held cannot spuriously release (or re-press) the remote
        // modifier. The left keysym is the stable wire representation per group.
        reconcileModifiers(with: event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        guard controlEnabled else {
            super.keyDown(with: event)
            return
        }
        handleKeyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        guard controlEnabled else {
            super.keyUp(with: event)
            return
        }

        let keysym = pressedKeysymsByKeyCode.removeValue(forKey: event.keyCode) ?? keysym(for: event)
        if let keysym {
            delegate?.interactionOverlayView(self, sendKeyDown: false, keysym: keysym)
        }
        reconcileModifiers(with: event.modifierFlags)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard controlEnabled,
              window?.firstResponder === self,
              event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        handleKeyDown(event)
        return true
    }

    private func handleKeyDown(_ event: NSEvent) {
        reconcileModifiers(with: event.modifierFlags)
        guard let keysym = keysym(for: event) else { return }

        if !event.isARepeat {
            pressedKeysymsByKeyCode[event.keyCode] = keysym
        }
        delegate?.interactionOverlayView(self, sendKeyDown: true, keysym: keysym)
    }

    private func keysym(for event: NSEvent) -> UInt32? {
        if let special = specialKeysym(for: event.keyCode) {
            return special
        }

        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        let value = scalar.value
        if value >= 0x20, value <= 0xFF {
            return value
        }
        if value <= 0x10FFFF {
            return 0x01000000 | value
        }
        return nil
    }

    private func specialKeysym(for keyCode: UInt16) -> UInt32? {
        switch keyCode {
        case 36: return KeySym.returnKey
        case 48: return KeySym.tab
        case 51: return KeySym.backspace
        case 53: return KeySym.escape
        case 76: return KeySym.keypadEnter
        case 114: return KeySym.insert
        case 115: return KeySym.home
        case 116: return KeySym.pageUp
        case 117: return KeySym.delete
        case 119: return KeySym.end
        case 121: return KeySym.pageDown
        case 123: return KeySym.left
        case 124: return KeySym.right
        case 125: return KeySym.down
        case 126: return KeySym.up
        case 122: return KeySym.function1       // F1
        case 120: return KeySym.function1 + 1   // F2
        case 99: return KeySym.function1 + 2    // F3
        case 118: return KeySym.function1 + 3   // F4
        case 96: return KeySym.function1 + 4    // F5
        case 97: return KeySym.function1 + 5    // F6
        case 98: return KeySym.function1 + 6    // F7
        case 100: return KeySym.function1 + 7   // F8
        case 101: return KeySym.function1 + 8   // F9
        case 109: return KeySym.function1 + 9   // F10
        case 103: return KeySym.function1 + 10  // F11
        case 111: return KeySym.function1 + 11  // F12
        case 105: return KeySym.function1 + 12  // F13
        case 107: return KeySym.function1 + 13  // F14
        case 113: return KeySym.function1 + 14  // F15
        case 106: return KeySym.function1 + 15  // F16
        case 64: return KeySym.function1 + 16   // F17
        case 79: return KeySym.function1 + 17   // F18
        case 80: return KeySym.function1 + 18   // F19
        case 90: return KeySym.function1 + 19   // F20
        default: return nil
        }
    }

    private func reconcileModifiers(with flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        reconcileModifierGroup(
            isDown: flags.contains(.shift),
            keysyms: [KeySym.shiftLeft, KeySym.shiftRight],
            fallback: KeySym.shiftLeft
        )
        reconcileModifierGroup(
            isDown: flags.contains(.control),
            keysyms: [KeySym.controlLeft, KeySym.controlRight],
            fallback: KeySym.controlLeft
        )
        reconcileModifierGroup(
            isDown: flags.contains(.option),
            keysyms: [KeySym.altLeft, KeySym.altRight],
            fallback: KeySym.altLeft
        )
        reconcileModifierGroup(
            isDown: flags.contains(.command),
            keysyms: [KeySym.metaLeft, KeySym.metaRight],
            fallback: KeySym.metaLeft
        )
    }

    private func reconcileModifierGroup(isDown: Bool, keysyms: [UInt32], fallback: UInt32) {
        let active = keysyms.filter { activeModifierKeysyms.contains($0) }
        if isDown, active.isEmpty {
            activeModifierKeysyms.insert(fallback)
            delegate?.interactionOverlayView(self, sendKeyDown: true, keysym: fallback)
        } else if !isDown {
            for keysym in active {
                activeModifierKeysyms.remove(keysym)
                delegate?.interactionOverlayView(self, sendKeyDown: false, keysym: keysym)
            }
        }
    }

    /// Releases every locally tracked pointer button and key. The delegate is
    /// responsible for flushing its own wire-level state as one serialized action.
    func releaseAllInputs() {
        let hadActiveInput = activePointerMask != 0 ||
            !pressedKeysymsByKeyCode.isEmpty ||
            !activeModifierKeysyms.isEmpty

        activePointerMask = 0
        lastPointerPoint = nil
        lastDragTimestamp = -Double.infinity
        wheelAccumulator = 0
        pressedKeysymsByKeyCode.removeAll(keepingCapacity: true)
        activeModifierKeysyms.removeAll(keepingCapacity: true)

        if hadActiveInput {
            delegate?.interactionOverlayViewDidRequestReleaseAllInputs(self)
        }
    }
}
