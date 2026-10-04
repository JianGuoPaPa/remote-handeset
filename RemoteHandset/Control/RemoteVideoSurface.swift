import SwiftUI
import UIKit
import WebRTC
import CoreImage
#if !targetEnvironment(simulator)
import MetalKit
#endif

struct RemoteVideoSurface: UIViewRepresentable {
    let videoTrack: RTCVideoTrack?
    let remoteSize: CGSize
    let isControlEnabled: Bool
    let onTouch: (
        RemoteTouchAction,
        UInt8,
        UInt16,
        UInt16,
        UInt16,
        UInt8
    ) -> Void
    let onSurfaceInteraction: () -> Void

    func makeUIView(context: Context) -> RemoteTouchVideoView {
        let view = RemoteTouchVideoView()
        view.remoteSize = remoteSize
        view.isControlEnabled = isControlEnabled
        view.onTouch = onTouch
        view.onSurfaceInteraction = onSurfaceInteraction
        view.setVideoTrack(videoTrack)
        return view
    }

    func updateUIView(_ uiView: RemoteTouchVideoView, context: Context) {
        uiView.remoteSize = remoteSize
        uiView.isControlEnabled = isControlEnabled
        uiView.onTouch = onTouch
        uiView.onSurfaceInteraction = onSurfaceInteraction
        uiView.setVideoTrack(videoTrack)
    }

    static func dismantleUIView(_ uiView: RemoteTouchVideoView, coordinator: ()) {
        uiView.releaseAllTouches()
        uiView.setVideoTrack(nil)
    }
}

final class RemoteTouchVideoView: UIView {
    var remoteSize = CGSize(width: 720, height: 1280) {
        didSet {
            guard remoteSize != oldValue else { return }
            releaseAllTouches()
            setNeedsLayout()
        }
    }
    var isControlEnabled = false {
        didSet {
            if !isControlEnabled {
                releaseAllTouches()
            }
        }
    }
    var onTouch: ((
        RemoteTouchAction,
        UInt8,
        UInt16,
        UInt16,
        UInt16,
        UInt8
    ) -> Void)?
    var onSurfaceInteraction: (() -> Void)?

#if targetEnvironment(simulator)
    private let renderer = SimulatorVideoRendererView(frame: .zero)
#else
    private let renderer = DeviceMetalVideoRendererView(frame: .zero)
#endif
    private weak var currentTrack: RTCVideoTrack?
    private var touchIDs: [ObjectIdentifier: UInt8] = [:]
    private var lastTouchPayload: [UInt8: TouchPayload] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = true
        backgroundColor = .black

        renderer.contentMode = .scaleAspectFit
        renderer.isUserInteractionEnabled = false
        addSubview(renderer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        currentTrack?.remove(renderer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
#if targetEnvironment(simulator)
        renderer.frame = bounds
#else
        renderer.frame = aspectFitRect(contentSize: remoteSize, in: bounds)
#endif
    }

    func setVideoTrack(_ track: RTCVideoTrack?) {
        guard currentTrack !== track else { return }
        currentTrack?.remove(renderer)
        currentTrack = track
        track?.add(renderer)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onSurfaceInteraction?()
        guard isControlEnabled else { return }
        for touch in touches {
            guard let payload = payload(for: touch),
                  let pointerID = reservePointerID(for: touch)
            else {
                continue
            }
            lastTouchPayload[pointerID] = payload
            onTouch?(.down, pointerID, payload.x, payload.y, payload.pressure, 1)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isControlEnabled else { return }
        for touch in touches {
            guard let pointerID = touchIDs[ObjectIdentifier(touch)] else { continue }
            let source = event?.coalescedTouches(for: touch)?.last ?? touch
            if let payload = payload(for: source) {
                lastTouchPayload[pointerID] = payload
                onTouch?(.move, pointerID, payload.x, payload.y, payload.pressure, 1)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouches(touches)
    }

    func releaseAllTouches() {
        for (pointerID, payload) in lastTouchPayload {
            onTouch?(.up, pointerID, payload.x, payload.y, 0, 0)
        }
        touchIDs.removeAll()
        lastTouchPayload.removeAll()
    }

    private func finishTouches(_ touches: Set<UITouch>) {
        guard isControlEnabled else { return }
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            guard let pointerID = touchIDs.removeValue(forKey: identifier) else { continue }
            let payload = payload(for: touch) ?? lastTouchPayload[pointerID]
            if let payload {
                onTouch?(.up, pointerID, payload.x, payload.y, 0, 0)
            }
            lastTouchPayload.removeValue(forKey: pointerID)
        }
    }

    private func reservePointerID(for touch: UITouch) -> UInt8? {
        let identifier = ObjectIdentifier(touch)
        if let existing = touchIDs[identifier] {
            return existing
        }
        let used = Set(touchIDs.values)
        guard let available = (0..<10).map(UInt8.init).first(where: { !used.contains($0) }) else {
            return nil
        }
        touchIDs[identifier] = available
        return available
    }

    private func payload(for touch: UITouch) -> TouchPayload? {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return nil }
        let location = touch.location(in: self)
        let contentRect = aspectFitRect(contentSize: remoteSize, in: bounds)
        guard contentRect.width > 0,
              contentRect.height > 0,
              contentRect.contains(location)
        else {
            return nil
        }

        let normalizedX = (location.x - contentRect.minX) / contentRect.width
        let normalizedY = (location.y - contentRect.minY) / contentRect.height
        let x = UInt16(
            min(
                max(round(normalizedX * max(remoteSize.width - 1, 0)), 0),
                Double(UInt16.max)
            )
        )
        let y = UInt16(
            min(
                max(round(normalizedY * max(remoteSize.height - 1, 0)), 0),
                Double(UInt16.max)
            )
        )

        let normalizedPressure: CGFloat
        if touch.maximumPossibleForce > 0 {
            normalizedPressure = min(max(touch.force / touch.maximumPossibleForce, 0.05), 1)
        } else {
            normalizedPressure = 1
        }
        let pressure = UInt16(round(normalizedPressure * CGFloat(UInt16.max)))
        return TouchPayload(x: x, y: y, pressure: pressure)
    }

    private func aspectFitRect(contentSize: CGSize, in container: CGRect) -> CGRect {
        let scale = min(container.width / contentSize.width, container.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: container.midX - size.width / 2,
            y: container.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct TouchPayload {
    let x: UInt16
    let y: UInt16
    let pressure: UInt16
}

#if targetEnvironment(simulator)
private final class SimulatorVideoRendererView: UIView, RTCVideoRenderer {
    private let imageView = UIImageView(frame: .zero)
    private let renderQueue = DispatchQueue(
        label: "com.dltengwen.remotehandset.simulator-renderer",
        qos: .userInteractive
    )
    private let renderLock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var isRendering = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame,
              let buffer = frame.buffer as? RTCCVPixelBuffer
        else {
            return
        }

        renderLock.lock()
        guard !isRendering else {
            renderLock.unlock()
            return
        }
        isRendering = true
        renderLock.unlock()

        let pixelBuffer = buffer.pixelBuffer
        let rotation = frame.rotation
        renderQueue.async { [weak self] in
            guard let self else { return }
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            switch rotation {
            case ._90:
                image = image.oriented(.right)
            case ._180:
                image = image.oriented(.down)
            case ._270:
                image = image.oriented(.left)
            case ._0:
                break
            @unknown default:
                break
            }

            let output = self.context.createCGImage(
                image,
                from: image.extent
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let output {
                    self.imageView.image = UIImage(cgImage: output)
                }
                self.renderLock.lock()
                self.isRendering = false
                self.renderLock.unlock()
            }
        }
    }
}
#else
private final class DeviceMetalVideoRendererView: UIView, RTCVideoRenderer, MTKViewDelegate {
    private let metalView: MTKView
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let outputColorSpace = CGColorSpaceCreateDeviceRGB()
    private let frameLock = NSLock()
    private var pendingFrame: RTCVideoFrame?
    private var isRenderScheduled = false

    override init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            fatalError("Metal rendering is unavailable on this device")
        }

        metalView = MTKView(frame: .zero, device: device)
        self.commandQueue = commandQueue
        context = CIContext(
            mtlDevice: device,
            options: [.cacheIntermediates: false]
        )

        super.init(frame: frame)

        isOpaque = true
        backgroundColor = .black
        metalView.isOpaque = true
        metalView.backgroundColor = .black
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = false
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.autoResizeDrawable = false
        metalView.presentsWithTransaction = false
        metalView.isUserInteractionEnabled = false
        metalView.delegate = self
        addSubview(metalView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds

        let scale = window?.screen.scale ?? UIScreen.main.scale
        let drawableSize = CGSize(
            width: max(bounds.width * scale, 1),
            height: max(bounds.height * scale, 1)
        )
        if metalView.drawableSize != drawableSize {
            metalView.drawableSize = drawableSize
        }
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }

        frameLock.lock()
        pendingFrame = frame
        let shouldSchedule = !isRenderScheduled
        if shouldSchedule {
            isRenderScheduled = true
        }
        frameLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.metalView.draw()
        }
    }

    func draw(in view: MTKView) {
        frameLock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        frameLock.unlock()

        guard let frame,
              window != nil,
              view.drawableSize.width > 1,
              view.drawableSize.height > 1,
              let pixelBuffer = frame.buffer as? RTCCVPixelBuffer,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            finishRenderCycle()
            return
        }

        let targetRect = CGRect(
            origin: .zero,
            size: view.drawableSize
        )
        let sourceImage = orientedImage(
            CIImage(cvPixelBuffer: pixelBuffer.pixelBuffer),
            rotation: frame.rotation
        )
        let outputImage = aspectFit(
            sourceImage,
            in: targetRect
        )

        context.render(
            outputImage,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: targetRect,
            colorSpace: outputColorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            _ = frame
            DispatchQueue.main.async {
                self?.finishRenderCycle()
            }
        }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func finishRenderCycle() {
        frameLock.lock()
        let shouldContinue = pendingFrame != nil
        if !shouldContinue {
            isRenderScheduled = false
        }
        frameLock.unlock()

        if shouldContinue {
            DispatchQueue.main.async { [weak self] in
                self?.metalView.draw()
            }
        }
    }

    private func orientedImage(
        _ image: CIImage,
        rotation: RTCVideoRotation
    ) -> CIImage {
        switch rotation {
        case ._90:
            return image.oriented(.right)
        case ._180:
            return image.oriented(.down)
        case ._270:
            return image.oriented(.left)
        case ._0:
            return image
        @unknown default:
            return image
        }
    }

    private func aspectFit(_ image: CIImage, in targetRect: CGRect) -> CIImage {
        let normalized = image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            )
        )
        let scale = min(
            targetRect.width / normalized.extent.width,
            targetRect.height / normalized.extent.height
        )
        let scaled = normalized.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let positioned = scaled.transformed(
            by: CGAffineTransform(
                translationX: targetRect.midX - scaled.extent.midX,
                y: targetRect.midY - scaled.extent.midY
            )
        )
        let background = CIImage(color: .black).cropped(to: targetRect)
        return positioned.composited(over: background).cropped(to: targetRect)
    }
}
#endif
