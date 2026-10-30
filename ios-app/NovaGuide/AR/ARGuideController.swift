import ARKit
import AVFoundation
import CoreImage
import RealityKit
import UIKit

/// One camera frame as it was when the question was asked: the JPEG sent to the Mac plus what is needed to turn the
/// answer's 2D points into world positions later, after the phone has moved.
struct CapturedFrame {
    var jpeg: Data  // upright for the interface orientation at capture time
    var imageSize: CGSize  // the sensor image's resolution; intrinsics are in these pixels
    var orientation: FrameOrientation = .landscapeRight
    var intrinsics: simd_float3x3
    var cameraTransform: simd_float4x4
    var depth: DepthSample?

    var cameraInfo: GuideClient.CameraInfo {
        let i = intrinsics, t = cameraTransform
        return GuideClient.CameraInfo(
            imageWidth: Int(imageSize.width), imageHeight: Int(imageSize.height),
            intrinsics: [i[0], i[1], i[2]].flatMap { [$0.x, $0.y, $0.z] },
            transform: [t[0], t[1], t[2], t[3]].flatMap { [$0.x, $0.y, $0.z, $0.w] },
            orientation: orientation.rawValue)
    }
}

/// Where a step's control (and, for a dial, its target label) sits in the world.
struct StepAnchor {
    var control: SIMD3<Float>
    var radius: Float  // meters
    var label: SIMD3<Float>?
    /// Placed from LiDAR depth or a surface raycast; false means a guess at a fixed distance.
    var precise: Bool
}

/// The current step's marker, projected onto the screen for this display frame.
struct MarkerState: Equatable {
    var center: CGPoint
    var radius: CGFloat
    var onScreen: Bool
    /// Unit vector in screen space (y down) from the screen's center toward the control.
    var direction: CGVector
    var label: CGPoint?
    var precise: Bool
}

/// The camera choices from Settings › Camera.
struct CameraOptions: Equatable {
    var lens: LensChoice = .widest
    var highDetail = false
    var torch: TorchChoice = .automatic
}

/// Owns the AR session. ARKit is used only for tracking and geometry (depth, raycasts); every recognition task
/// stays with Meta's models on the Mac (HACKATHON.md, Approved Exceptions, 2026-10-27).
final class ARGuideController: NSObject, ObservableObject, ARSessionDelegate {
    static let maxImageSide: CGFloat = 1600
    static let guessDistance: Float = 0.6

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    @Published private(set) var marker: MarkerState?
    @Published private(set) var trackingIssue: String?

    var currentStep: Int? { didSet { updateMarker() } }
    /// The camera ARKit is running, for Settings: "Ultra wide · 1920×1440".
    @Published private(set) var activeCamera = ""
    private(set) var options = CameraOptions()
    private var running = false
    /// Whether the torch is lit now, for the top bar's torch button.
    @Published private(set) var torchOn = false
    private var autoTorch = AutoTorch()
    /// The user turned the torch off from the top bar; it stays off until the task ends.
    private var torchSuppressed = false
    /// Nova is listening or waiting for a model: the automatic torch doesn't blink to measure the room.
    var holdTorch = false
    private(set) var anchors: [StepAnchor] = []
    private var displayLink: CADisplayLink?
    private let ciContext = CIContext()

    var hasLiDAR: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    /// The interface orientation, as the turn that makes the sensor image upright.
    var frameOrientation: FrameOrientation {
        switch arView.window?.windowScene?.interfaceOrientation {
        case .portrait, .portraitUpsideDown: .portrait
        case .landscapeLeft: .landscapeLeft
        default: .landscapeRight
        }
    }

    func start() {
        let configuration = ARWorldTrackingConfiguration()
        if let format = Self.videoFormat(for: options, from: ARWorldTrackingConfiguration.supportedVideoFormats) {
            configuration.videoFormat = format
        }
        activeCamera = Self.describe(configuration.videoFormat)
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        arView.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disablePersonOcclusion, .disableGroundingShadows]
        arView.session.delegate = self
        arView.session.run(configuration)
        running = true
        applyTorch()
        #if DEBUG
        for format in ARWorldTrackingConfiguration.supportedVideoFormats {
            print("Nova camera format:", format.captureDeviceType.rawValue, Self.describe(format), format.framesPerSecond, "fps")
        }
        print("Nova camera in use:", activeCamera)
        #endif
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    func pause() {
        running = false
        applyTorch()  // off while the camera is paused
        arView.session.pause()
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: Camera options

    /// Whether ARKit can track with the ultra wide camera on this iPhone. An iPhone 15 Pro offers the wide camera only
    /// (1920×1440 by default, 4K for high detail), so there is no lens to choose there.
    static var hasUltraWide: Bool {
        ARWorldTrackingConfiguration.supportedVideoFormats.contains { $0.captureDeviceType == .builtInUltraWideCamera }
    }

    /// Settings › Camera changed: a new lens or resolution restarts the session; the torch just switches.
    func apply(_ new: CameraOptions) {
        let restart = new.lens != options.lens || new.highDetail != options.highDetail
        options = new
        if restart && running {
            start()
        } else {
            applyTorch()
        }
    }

    /// The widest camera ARKit offers for world tracking when the lens is "widest" (ultra wide where this iPhone
    /// supports it), and its highest resolution for high detail; otherwise ARKit's own first choice.
    static func videoFormat(for options: CameraOptions, from formats: [ARConfiguration.VideoFormat]) -> ARConfiguration.VideoFormat? {
        let ultraWide = formats.filter { $0.captureDeviceType == .builtInUltraWideCamera }
        let wide = formats.filter { $0.captureDeviceType == .builtInWideAngleCamera }
        let pool = options.lens == .widest && !ultraWide.isEmpty ? ultraWide : (wide.isEmpty ? formats : wide)
        guard !pool.isEmpty else { return nil }
        if options.highDetail {
            return pool.max { $0.imageResolution.width * $0.imageResolution.height < $1.imageResolution.width * $1.imageResolution.height }
        }
        return pool.first
    }

    private static func describe(_ format: ARConfiguration.VideoFormat) -> String {
        let camera = format.captureDeviceType == .builtInUltraWideCamera ? String(localized: "Ultra wide") : String(localized: "Wide")
        return "\(camera) · \(Int(format.imageResolution.width))×\(Int(format.imageResolution.height))"
    }

    /// The torch belongs to the back camera module; ARKit hands out the device it runs, and the wide camera has the
    /// torch when the ultra wide one doesn't.
    private func applyTorch() {
        let wanted = running && !torchSuppressed && (options.torch == .on || (options.torch == .automatic && autoTorch.isLit))
        if torchOn != wanted { DispatchQueue.main.async { self.torchOn = wanted } }
        let candidates = [ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
                          AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)]
        guard let device = candidates.compactMap({ $0 }).first(where: { $0.hasTorch && $0.isTorchAvailable }) else { return }
        let mode: AVCaptureDevice.TorchMode = wanted ? .on : .off
        guard device.torchMode != mode, (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = mode
        device.unlockForConfiguration()
    }

    /// The top bar's torch button: off for the rest of this task.
    func turnTorchOffForTask() {
        torchSuppressed = true
        applyTorch()
    }

    /// A task ended (completed, Home, new task): the automatic torch goes off and may come on again in the dark.
    func taskEnded() {
        autoTorch.reset()
        torchSuppressed = false
        applyTorch()
    }

    // MARK: Capture

    /// The current frame, or nil while tracking is not ready.
    func capture() -> CapturedFrame? {
        guard let frame = arView.session.currentFrame else { return nil }
        let pixelBuffer = frame.capturedImage
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        // Turned to the interface orientation, so Spark reads the panel's labels upright.
        let orientation = frameOrientation
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation.imageOrientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(1, Self.maxImageSide / max(size.width, size.height))
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(
                of: image, colorSpace: space,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8])
        else { return nil }
        return CapturedFrame(jpeg: jpeg, imageSize: size, orientation: orientation, intrinsics: frame.camera.intrinsics,
                             cameraTransform: frame.camera.transform, depth: Self.copyDepth(frame))
    }

    enum CloseUp {
        case jpeg(Data)
        case offScreen
        case tooSmall
        case notReady
    }

    /// A full-resolution close-up of a step's control in the current frame, for step verification.
    func closeUp(step index: Int) -> CloseUp {
        guard anchors.indices.contains(index), let frame = arView.session.currentFrame,
              case .normal = frame.camera.trackingState else { return .notReady }
        let anchor = anchors[index]
        let pixelBuffer = frame.capturedImage
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let camera = frame.camera
        guard (simd_inverse(camera.transform) * SIMD4<Float>(anchor.control, 1)).z < 0 else { return .offScreen }
        // With the viewport set to the captured image's size, projectPoint returns that image's pixels.
        let center = camera.projectPoint(anchor.control, orientation: .landscapeRight, viewportSize: size)
        let right = SIMD3<Float>(camera.transform.columns.0.x, camera.transform.columns.0.y, camera.transform.columns.0.z)
        let edge = camera.projectPoint(anchor.control + right * anchor.radius, orientation: .landscapeRight, viewportSize: size)
        let radius = max(hypot(edge.x - center.x, edge.y - center.y), 8)
        let label = anchor.label.map { camera.projectPoint($0, orientation: .landscapeRight, viewportSize: size) }
        switch CropGeometry.crop(control: center, radius: radius, label: label, imageSize: size) {
        case .offScreen: return .offScreen
        case .tooSmall: return .tooSmall
        case .crop(let rect):
            // Core Image's origin is bottom-left.
            let flipped = CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
            var image = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: flipped)
            image = image.transformed(by: CGAffineTransform(translationX: -flipped.minX, y: -flipped.minY))
            image = image.oriented(frameOrientation.imageOrientation)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let scale = min(1, 1024 / max(rect.width, rect.height))
            if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let jpeg = ciContext.jpegRepresentation(
                    of: image, colorSpace: space,
                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
            else { return .notReady }
            return .jpeg(jpeg)
        }
    }

    private static func copyDepth(_ frame: ARFrame) -> DepthSample? {
        guard let map = frame.sceneDepth?.depthMap, CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<width { values[y * width + x] = row[x] }
        }
        return DepthSample(width: width, height: height, values: values)
    }

    // MARK: Anchoring

    /// Turns the plan's 2D points into world positions, using the camera as it was when the frame was captured.
    /// Steps before `start` keep their markers: they were corrected from a later frame.
    func place(_ plan: GuidePlan, from capture: CapturedFrame, startingAt start: Int = 0) {
        anchors = Array(anchors.prefix(start)) + plan.steps.dropFirst(start).map { anchor(for: $0, capture) }
        updateMarker()
    }

    /// One step located again from a newer frame ("Re-evaluate").
    func relocate(step index: Int, to step: GuideStep, from capture: CapturedFrame) {
        guard anchors.indices.contains(index) else { return }
        anchors[index] = anchor(for: step, capture)
        updateMarker()
    }

    private func anchor(for step: GuideStep, _ capture: CapturedFrame) -> StepAnchor {
        let center = step.markerPoint
        let (control, distance, precise) = locate(center, capture)
        var radius: Float = 0.025
        if let box = step.box, step.boxMethod == "point" || step.boxMethod == "fallback" {
            let upright = capture.orientation.uprightSize(capture.imageSize)
            let pixels = max(box.width * upright.width, box.height * upright.height) / 2
            radius = min(max(CameraGeometry.meters(pixels: pixels, depth: distance, intrinsics: capture.intrinsics), 0.012), 0.08)
        }
        let label = step.setTo?.point.map { locate($0, capture).position }
        return StepAnchor(control: control, radius: radius, label: label, precise: precise)
    }

    func clear() {
        anchors = []
        currentStep = nil
    }

    /// A corrected plan: only the steps before `count` stay marked until the new ones are located.
    func keepAnchors(first count: Int) {
        anchors = Array(anchors.prefix(count))
    }

    /// "It's pointing at the wrong place": the user tapped the right control. A surface raycast at the tap, or else the
    /// marker's own distance along the tap's ray.
    func moveMarker(step index: Int, toScreen point: CGPoint) -> Bool {
        guard anchors.indices.contains(index), let ray = arView.ray(through: point) else { return false }
        if let hit = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first {
            let column = hit.worldTransform.columns.3
            anchors[index] = StepAnchor(control: SIMD3(column.x, column.y, column.z), radius: 0.025, label: nil, precise: true)
        } else {
            let distance = simd_distance(anchors[index].control, ray.origin)
            anchors[index] = StepAnchor(control: ray.origin + ray.direction * distance, radius: 0.025, label: nil, precise: false)
        }
        updateMarker()
        return true
    }

    /// LiDAR depth at the point first, then a raycast from the capture-time camera, then a fixed-distance guess.
    /// The point is in the upright frame that was sent; depth and intrinsics are in the sensor image.
    private func locate(_ point: NormalizedPoint, _ capture: CapturedFrame) -> (position: SIMD3<Float>, depth: Float, precise: Bool) {
        let sensor = capture.orientation.sensorPoint(CGPoint(x: point.x, y: point.y))
        let pixel = CGPoint(x: sensor.x * capture.imageSize.width, y: sensor.y * capture.imageSize.height)
        if let depth = capture.depth?.depth(atNormalized: sensor) {
            let position = CameraGeometry.worldPoint(pixel: pixel, depth: depth, intrinsics: capture.intrinsics,
                                                     cameraTransform: capture.cameraTransform)
            return (position, depth, true)
        }
        let ray = CameraGeometry.worldRay(pixel: pixel, intrinsics: capture.intrinsics, cameraTransform: capture.cameraTransform)
        let query = ARRaycastQuery(origin: ray.origin, direction: ray.direction, allowing: .estimatedPlane, alignment: .any)
        if let hit = arView.session.raycast(query).first {
            let column = hit.worldTransform.columns.3
            let position = SIMD3<Float>(column.x, column.y, column.z)
            return (position, simd_distance(position, ray.origin), true)
        }
        let position = CameraGeometry.worldPoint(pixel: pixel, depth: Self.guessDistance, intrinsics: capture.intrinsics,
                                                 cameraTransform: capture.cameraTransform)
        return (position, Self.guessDistance, false)
    }

    // MARK: Projection

    @objc private func tick() { updateMarker() }

    private func updateMarker() {
        #if DEBUG
        if demoMarker { return }
        #endif
        guard let index = currentStep, anchors.indices.contains(index), arView.bounds.width > 0 else {
            if marker != nil { marker = nil }
            return
        }
        let anchor = anchors[index]
        let bounds = arView.bounds
        let cameraMatrix = arView.cameraTransform.matrix
        let local = simd_inverse(cameraMatrix) * SIMD4<Float>(anchor.control, 1)
        let screenCenter = CGPoint(x: bounds.midX, y: bounds.midY)

        var state = MarkerState(center: screenCenter, radius: 0, onScreen: false, direction: CGVector(dx: 0, dy: -1),
                                label: nil, precise: anchor.precise)
        if local.z < 0, let center = arView.project(anchor.control) {
            let right = SIMD3<Float>(cameraMatrix.columns.0.x, cameraMatrix.columns.0.y, cameraMatrix.columns.0.z)
            if let edge = arView.project(anchor.control + right * anchor.radius) {
                state.radius = max(hypot(edge.x - center.x, edge.y - center.y), 18)
            }
            state.center = center
            state.onScreen = bounds.insetBy(dx: 12, dy: 12).contains(center)
            if let label = anchor.label, (simd_inverse(cameraMatrix) * SIMD4<Float>(label, 1)).z < 0 {
                state.label = arView.project(label)
            }
        }
        if !state.onScreen {
            // Camera space: x right, y up. Screen: y down.
            let dx = CGFloat(local.x), dy = CGFloat(-local.y)
            let length = max(hypot(dx, dy), 0.0001)
            state.direction = local.z < 0 || length > 0.01 ? CGVector(dx: dx / length, dy: dy / length) : CGVector(dx: 0, dy: -1)
        }
        if marker != state { marker = state }
    }

    #if DEBUG
    private var demoMarker = false

    /// Simulator screenshots only: a fixed marker, since ARKit doesn't run in the simulator.
    func showDemoMarker(_ state: MarkerState?) {
        demoMarker = true
        marker = state
    }
    #endif

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard options.torch == .automatic, let lumens = frame.lightEstimate?.ambientIntensity else { return }
        let was = autoTorch.isLit
        if autoTorch.update(lumens: Double(lumens), at: frame.timestamp, hold: holdTorch) != was { applyTorch() }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let issue: String?
        switch camera.trackingState {
        case .normal: issue = nil
        case .notAvailable: issue = String(localized: "Camera tracking is not available.")
        case .limited(.excessiveMotion): issue = String(localized: "Move the phone more slowly.")
        case .limited(.insufficientFeatures): issue = String(localized: "Point the camera at the device in better light.")
        case .limited: issue = String(localized: "Hold the phone steady for a moment.")
        }
        DispatchQueue.main.async { self.trackingIssue = issue }
    }
}
