import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore

/// A latest-frame-first preview for `USBScreenCapture`.
///
/// Unlike `AVCaptureVideoPreviewLayer`, this view owns the sample scheduling
/// policy. Every frame is marked `kCMSampleAttachmentKey_DisplayImmediately`
/// and is enqueued without a control timebase, so an old presentation timestamp
/// cannot intentionally hold the frame in a playback queue. No pixel copy or
/// re-encoding is performed.
///
/// `videoRect` uses this flipped view's local, top-left coordinate system. A
/// same-sized flipped interaction overlay can use the rect directly.
@MainActor
final class LowLatencyVideoPreviewView: NSView {
    private(set) var displayLayer = AVSampleBufferDisplayLayer()

    private(set) var videoRect: CGRect = .zero

    /// Invoked on the main actor only when the effective video rect changes.
    var onVideoRectChange: ((CGRect) -> Void)? {
        didSet {
            onVideoRectChange?(videoRect)
        }
    }

    var videoGravity: AVLayerVideoGravity {
        get { displayLayer.videoGravity }
        set {
            guard displayLayer.videoGravity != newValue else { return }
            displayLayer.videoGravity = newValue
            updateVideoRect()
        }
    }

    /// The capture supplying frames. Assignment installs a synchronous sample
    /// callback; assigning nil detaches and removes the displayed image.
    var capture: USBScreenCapture? {
        get { captureBinding?.capture }
        set { bind(to: newValue) }
    }

    override var isFlipped: Bool { true }

    private let geometryRelay = GeometryRelay()
    private let renderer: LatestFrameRenderer
    private var captureBinding: CaptureBinding?
    private var sourceSize: CGSize = .zero
    private var displayLayerRecoveryTimes: [TimeInterval] = []

    override init(frame frameRect: NSRect) {
        renderer = LatestFrameRenderer(displayLayer: displayLayer, geometryRelay: geometryRelay)
        super.init(frame: frameRect)
        commonInit()
        geometryRelay.view = self
    }

    required init?(coder: NSCoder) {
        renderer = LatestFrameRenderer(displayLayer: displayLayer, geometryRelay: geometryRelay)
        super.init(coder: coder)
        commonInit()
        geometryRelay.view = self
    }

    override func makeBackingLayer() -> CALayer {
        let backingLayer = CALayer()
        backingLayer.backgroundColor = NSColor.black.cgColor
        return backingLayer
    }

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        displayLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        CATransaction.commit()

        updateVideoRect()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// Connects the view to a capture source. Safe to call repeatedly.
    func bind(to newCapture: USBScreenCapture?) {
        if captureBinding?.capture === newCapture { return }

        captureBinding?.cancel()
        captureBinding = nil
        renderer.flush(removeDisplayedImage: true)
        applySourceSize(.zero)

        guard let newCapture else { return }
        let renderer = self.renderer
        let token = newCapture.setSampleBufferHandler { sampleBuffer, _ in
            renderer.enqueue(sampleBuffer)
        }
        captureBinding = CaptureBinding(capture: newCapture, token: token)
    }

    /// Discards queued frames. Preserving the current image avoids a black
    /// flash during transient capture recovery.
    func flush(removeDisplayedImage: Bool = false) {
        renderer.flush(removeDisplayedImage: removeDisplayedImage)
        if removeDisplayedImage {
            applySourceSize(.zero)
        }
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        configure(displayLayer: displayLayer, videoGravity: .resizeAspect)
        layer?.addSublayer(displayLayer)
        renderer.onDisplayLayerReplacementNeeded = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.replaceDisplayLayerAfterFailure()
            }
        }
    }

    private func configure(
        displayLayer: AVSampleBufferDisplayLayer,
        videoGravity: AVLayerVideoGravity
    ) {
        displayLayer.videoGravity = videoGravity
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.controlTimebase = nil
        displayLayer.isGeometryFlipped = false
    }

    private func replaceDisplayLayerAfterFailure() {
        let previousLayer = displayLayer
        let replacementLayer = AVSampleBufferDisplayLayer()
        configure(displayLayer: replacementLayer, videoGravity: previousLayer.videoGravity)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        replacementLayer.frame = bounds
        replacementLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        if let parent = previousLayer.superlayer {
            parent.replaceSublayer(previousLayer, with: replacementLayer)
        } else {
            layer?.addSublayer(replacementLayer)
        }
        CATransaction.commit()

        displayLayer = replacementLayer
        renderer.replaceDisplayLayer(replacementLayer)
        updateVideoRect()

        // If a fresh display layer also becomes permanently not-ready, the
        // problem is upstream in the post-detach CMIO graph. Rebuild capture's
        // session/input/output while leaving the independent control channel
        // and web server alive.
        let now = ProcessInfo.processInfo.systemUptime
        displayLayerRecoveryTimes.removeAll { now - $0 > 8 }
        displayLayerRecoveryTimes.append(now)
        if displayLayerRecoveryTimes.count >= 2 {
            displayLayerRecoveryTimes.removeAll(keepingCapacity: true)
            capture?.retry()
        }
    }

    fileprivate func applySourceSize(_ newSize: CGSize) {
        let sanitizedSize: CGSize
        if newSize.width.isFinite,
           newSize.height.isFinite,
           newSize.width > 0,
           newSize.height > 0 {
            sanitizedSize = newSize
        } else {
            sanitizedSize = .zero
        }

        guard sourceSize != sanitizedSize else { return }
        sourceSize = sanitizedSize
        updateVideoRect()
    }

    private func updateVideoRect() {
        let newRect = fittedVideoRect(sourceSize: sourceSize, in: bounds, gravity: videoGravity)
        guard !approximatelyEqual(videoRect, newRect) else { return }
        videoRect = newRect
        onVideoRectChange?(newRect)
    }

    private func fittedVideoRect(
        sourceSize: CGSize,
        in destination: CGRect,
        gravity: AVLayerVideoGravity
    ) -> CGRect {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              destination.width > 0,
              destination.height > 0
        else { return .zero }

        if gravity == .resize {
            return destination
        }

        let horizontalScale = destination.width / sourceSize.width
        let verticalScale = destination.height / sourceSize.height
        let scale = gravity == .resizeAspectFill
            ? max(horizontalScale, verticalScale)
            : min(horizontalScale, verticalScale)
        let renderedSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)

        return CGRect(
            x: destination.midX - renderedSize.width / 2,
            y: destination.midY - renderedSize.height / 2,
            width: renderedSize.width,
            height: renderedSize.height
        )
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let epsilon = 0.25
        return abs(lhs.origin.x - rhs.origin.x) < epsilon
            && abs(lhs.origin.y - rhs.origin.y) < epsilon
            && abs(lhs.width - rhs.width) < epsilon
            && abs(lhs.height - rhs.height) < epsilon
    }
}

private final class CaptureBinding {
    private let lock = NSLock()
    private weak var storedCapture: USBScreenCapture?
    private let token: UInt64
    private var cancelled = false

    var capture: USBScreenCapture? {
        lock.lock()
        defer { lock.unlock() }
        return cancelled ? nil : storedCapture
    }

    init(capture: USBScreenCapture, token: UInt64) {
        storedCapture = capture
        self.token = token
    }

    func cancel() {
        let captureToClear: USBScreenCapture?
        lock.lock()
        if cancelled {
            captureToClear = nil
        } else {
            cancelled = true
            captureToClear = storedCapture
            storedCapture = nil
        }
        lock.unlock()

        captureToClear?.clearSampleBufferHandler(ifMatching: token)
    }

    deinit {
        cancel()
    }
}

/// Bridges format changes from the capture queue back to AppKit without making
/// the real-time sample callback wait for the main actor.
private final class GeometryRelay: @unchecked Sendable {
    weak var view: LowLatencyVideoPreviewView?

    func publish(_ size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            self?.view?.applySourceSize(size)
        }
    }
}

/// A single-slot, latest-frame-first bridge between capture and rendering.
///
/// Capture callbacks only retain/replace `pendingSample` and return; potentially
/// blocking AVFoundation renderer work happens on `rendererQueue`. This makes
/// app-side queue depth strictly one frame and prevents old images from building
/// up behind a slow display submission.
private final class LatestFrameRenderer: @unchecked Sendable {
    var onDisplayLayerReplacementNeeded: (() -> Void)?

    private var displayLayer: AVSampleBufferDisplayLayer
    private let geometryRelay: GeometryRelay
    private let rendererQueue = DispatchQueue(
        label: "LatestFrameRenderer.render",
        qos: .userInteractive
    )
    private let stateLock = NSLock()

    private var isFlushing = false
    private var queuedFlushRequested = false
    private var queuedFlushRemovesImage = false
    private var queuedFlushIsReadinessRecovery = false
    private var activeFlushIsReadinessRecovery = false
    private var flushSequence: UInt64 = 0
    private var activeFlushSequence: UInt64 = 0
    private var lastSourceSize: CGSize = .zero
    private var pendingSample: CMSampleBuffer?
    private var drainScheduled = false
    private var readinessRetryScheduled = false
    private var notReadySinceUptimeNanoseconds: UInt64?
    private var readinessFlushAttempted = false
    private var displayLayerReplacementPending = false

    init(displayLayer: AVSampleBufferDisplayLayer, geometryRelay: GeometryRelay) {
        self.displayLayer = displayLayer
        self.geometryRelay = geometryRelay
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        else { return }

        publishSourceSizeIfNeeded(for: sampleBuffer)
        markForImmediateDisplay(sampleBuffer)

        stateLock.lock()
        pendingSample = sampleBuffer
        scheduleDrainLocked()
        stateLock.unlock()
    }

    func replaceDisplayLayer(_ replacement: AVSampleBufferDisplayLayer) {
        rendererQueue.async { [weak self] in
            guard let self else { return }
            stateLock.lock()
            displayLayer = replacement
            flushSequence &+= 1
            activeFlushSequence = flushSequence
            isFlushing = false
            queuedFlushRequested = false
            queuedFlushRemovesImage = false
            queuedFlushIsReadinessRecovery = false
            activeFlushIsReadinessRecovery = false
            readinessRetryScheduled = false
            notReadySinceUptimeNanoseconds = nil
            readinessFlushAttempted = false
            displayLayerReplacementPending = false
            scheduleDrainLocked()
            stateLock.unlock()
        }
    }

    func flush(removeDisplayedImage: Bool) {
        beginFlush(removeDisplayedImage: removeDisplayedImage, isReadinessRecovery: false)
    }

    private func beginFlush(
        removeDisplayedImage: Bool,
        isReadinessRecovery: Bool
    ) {
        stateLock.lock()
        if removeDisplayedImage {
            pendingSample = nil
            lastSourceSize = .zero
        }
        guard !isFlushing else {
            queuedFlushRequested = true
            queuedFlushRemovesImage = queuedFlushRemovesImage || removeDisplayedImage
            queuedFlushIsReadinessRecovery = queuedFlushIsReadinessRecovery || isReadinessRecovery
            stateLock.unlock()
            return
        }
        isFlushing = true
        activeFlushIsReadinessRecovery = isReadinessRecovery
        flushSequence &+= 1
        let sequence = flushSequence
        activeFlushSequence = sequence
        stateLock.unlock()

        rendererQueue.async { [weak self] in
            self?.performFlush(removeDisplayedImage: removeDisplayedImage, sequence: sequence)
        }
    }

    private func scheduleDrainLocked() {
        guard !drainScheduled, !isFlushing else { return }
        drainScheduled = true
        rendererQueue.async { [weak self] in
            self?.drainLatestSample()
        }
    }

    private func drainLatestSample() {
        let renderer = displayLayer.sampleBufferRenderer

        stateLock.lock()
        drainScheduled = false
        let flushing = isFlushing
        stateLock.unlock()
        guard !flushing else { return }

        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            beginFlush(removeDisplayedImage: false, isReadinessRecovery: true)
            return
        }

        guard renderer.isReadyForMoreMediaData else {
            handleRendererNotReady()
            return
        }

        stateLock.lock()
        notReadySinceUptimeNanoseconds = nil
        readinessFlushAttempted = false
        displayLayerReplacementPending = false
        stateLock.unlock()

        stateLock.lock()
        let sampleBuffer = pendingSample
        pendingSample = nil
        stateLock.unlock()

        guard let sampleBuffer else { return }
        renderer.enqueue(sampleBuffer)

        // A newer frame may have arrived while enqueue synchronously entered
        // AVFoundation's internal buffer queue. Submit that newest frame next.
        stateLock.lock()
        scheduleDrainLocked()
        stateLock.unlock()
    }

    private func handleRendererNotReady() {
        let now = DispatchTime.now().uptimeNanoseconds
        var shouldFlush = false
        var shouldReplaceLayer = false

        stateLock.lock()
        if notReadySinceUptimeNanoseconds == nil {
            notReadySinceUptimeNanoseconds = now
        }
        let since = notReadySinceUptimeNanoseconds ?? now
        let elapsed = now >= since ? now - since : 0
        if elapsed >= 350_000_000, !readinessFlushAttempted {
            readinessFlushAttempted = true
            notReadySinceUptimeNanoseconds = now
            shouldFlush = true
        } else if elapsed >= 1_000_000_000,
                  readinessFlushAttempted,
                  !displayLayerReplacementPending {
            displayLayerReplacementPending = true
            shouldReplaceLayer = true
        }
        stateLock.unlock()

        if shouldReplaceLayer {
            onDisplayLayerReplacementNeeded?()
        } else if shouldFlush {
            beginFlush(removeDisplayedImage: false, isReadinessRecovery: true)
        } else {
            scheduleReadinessRetry()
        }
    }

    private func scheduleReadinessRetry() {
        stateLock.lock()
        guard pendingSample != nil,
              !isFlushing,
              !readinessRetryScheduled
        else {
            stateLock.unlock()
            return
        }
        readinessRetryScheduled = true
        stateLock.unlock()

        rendererQueue.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
            guard let self else { return }
            stateLock.lock()
            readinessRetryScheduled = false
            scheduleDrainLocked()
            stateLock.unlock()
        }
    }

    private func performFlush(removeDisplayedImage: Bool, sequence: UInt64) {
        let renderer = displayLayer.sampleBufferRenderer
        renderer.flush(
            removingDisplayedImage: removeDisplayedImage
        ) { [weak self] in
            self?.rendererQueue.async { [weak self] in
                self?.finishFlush(sequence: sequence)
            }
        }
        rendererQueue.asyncAfter(deadline: .now() + .milliseconds(750)) { [weak self] in
            self?.flushTimedOut(sequence: sequence)
        }
    }

    private func finishFlush(sequence: UInt64) {
        var nextFlush: (removeDisplayedImage: Bool, isReadinessRecovery: Bool, sequence: UInt64)?

        stateLock.lock()
        guard isFlushing, activeFlushSequence == sequence else {
            stateLock.unlock()
            return
        }
        if queuedFlushRequested {
            let removeDisplayedImage = queuedFlushRemovesImage
            let isReadinessRecovery = queuedFlushIsReadinessRecovery
            queuedFlushRequested = false
            queuedFlushRemovesImage = false
            queuedFlushIsReadinessRecovery = false
            activeFlushIsReadinessRecovery = isReadinessRecovery
            flushSequence &+= 1
            activeFlushSequence = flushSequence
            nextFlush = (removeDisplayedImage, isReadinessRecovery, flushSequence)
        } else {
            let wasReadinessRecovery = activeFlushIsReadinessRecovery
            activeFlushIsReadinessRecovery = false
            isFlushing = false
            if wasReadinessRecovery {
                notReadySinceUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            } else {
                notReadySinceUptimeNanoseconds = nil
                readinessFlushAttempted = false
                displayLayerReplacementPending = false
            }
            scheduleDrainLocked()
        }
        stateLock.unlock()

        if let nextFlush {
            performFlush(
                removeDisplayedImage: nextFlush.removeDisplayedImage,
                sequence: nextFlush.sequence
            )
        }
    }

    private func flushTimedOut(sequence: UInt64) {
        var shouldReplaceLayer = false
        stateLock.lock()
        if isFlushing,
           activeFlushSequence == sequence,
           !displayLayerReplacementPending {
            displayLayerReplacementPending = true
            shouldReplaceLayer = true
        }
        stateLock.unlock()

        if shouldReplaceLayer {
            onDisplayLayerReplacementNeeded?()
        }
    }

    private func publishSourceSizeIfNeeded(for sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size: CGSize
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
           CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Video {
            size = CMVideoFormatDescriptionGetPresentationDimensions(
                formatDescription,
                usePixelAspectRatio: true,
                useCleanAperture: true
            )
        } else {
            size = CGSize(
                width: CVPixelBufferGetWidth(imageBuffer),
                height: CVPixelBufferGetHeight(imageBuffer)
            )
        }

        stateLock.lock()
        let changed = lastSourceSize != size
        if changed {
            lastSourceSize = size
        }
        stateLock.unlock()

        if changed {
            geometryRelay.publish(size)
        }
    }

    private func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachmentArray) > 0,
        let untypedDictionary = CFArrayGetValueAtIndex(attachmentArray, 0)
        else { return }

        let dictionary = unsafeBitCast(untypedDictionary, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}
