import AppKit
import AVFoundation
import QuartzCore

/// Layer-backed preview surface for `USBScreenCapture`.
///
/// `videoRect` is expressed in this view's local coordinate system with a
/// top-left origin. A same-sized flipped overlay can use it directly.
@MainActor
final class VideoPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    private(set) var videoRect: CGRect = .zero

    /// Invoked on the main actor only when the effective top-left video rect changes.
    var onVideoRectChange: ((CGRect) -> Void)? {
        didSet {
            if onVideoRectChange != nil {
                onVideoRectChange?(videoRect)
            }
        }
    }

    var session: AVCaptureSession? {
        get { previewLayer.session }
        set {
            guard previewLayer.session !== newValue else { return }
            previewLayer.session = newValue
            updateVideoRect()
        }
    }

    var videoGravity: AVLayerVideoGravity {
        get { previewLayer.videoGravity }
        set {
            guard previewLayer.videoGravity != newValue else { return }
            previewLayer.videoGravity = newValue
            updateVideoRect()
        }
    }

    override var isFlipped: Bool { true }

    private var videoRectPollTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        videoRectPollTimer?.invalidate()
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
        previewLayer.frame = bounds
        previewLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        CATransaction.commit()

        updateVideoRect()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopVideoRectPolling()
        } else {
            startVideoRectPolling()
            updateVideoRect()
        }
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.isGeometryFlipped = false
        layer?.addSublayer(previewLayer)
    }

    private func updateVideoRect() {
        let rawVideoRect: CGRect
        if session == nil {
            rawVideoRect = .zero
        } else {
            rawVideoRect = previewLayer.layerRectConverted(fromMetadataOutputRect:
                CGRect(x: 0, y: 0, width: 1, height: 1)
            )
        }
        let convertedRect = convertLayerVideoRectToTopLeftViewCoordinates(rawVideoRect)
        guard !approximatelyEqual(videoRect, convertedRect) else { return }
        videoRect = convertedRect
        onVideoRectChange?(convertedRect)
    }

    private func startVideoRectPolling() {
        guard videoRectPollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateVideoRect()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        videoRectPollTimer = timer
    }

    private func stopVideoRectPolling() {
        videoRectPollTimer?.invalidate()
        videoRectPollTimer = nil
    }

    private func convertLayerVideoRectToTopLeftViewCoordinates(_ layerRect: CGRect) -> CGRect {
        guard !layerRect.isEmpty,
              layerRect.origin.x.isFinite,
              layerRect.origin.y.isFinite,
              layerRect.width.isFinite,
              layerRect.height.isFinite
        else { return .zero }

        let layerBounds = previewLayer.bounds
        let layerFrame = previewLayer.frame
        let localX = layerRect.minX - layerBounds.minX
        let localYFromTop = layerBounds.maxY - layerRect.maxY

        return CGRect(
            x: layerFrame.minX + localX,
            y: layerFrame.minY + localYFromTop,
            width: layerRect.width,
            height: layerRect.height
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
