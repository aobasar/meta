import ARKit
import CoreImage
import RealityKit
import UIKit

/// One camera frame as it was when the question was asked: the JPEG sent to the Mac plus what is needed to turn the
/// answer's 2D points into world positions later, after the phone has moved.
struct CapturedFrame {
    var jpeg: Data
    var imageSize: CGSize  // the captured image's resolution; intrinsics are in these pixels
    var intrinsics: simd_float3x3
    var cameraTransform: simd_float4x4
    var depth: DepthSample?

    var cameraInfo: GuideClient.CameraInfo {
        let i = intrinsics, t = cameraTransform
        return GuideClient.CameraInfo(
            imageWidth: Int(imageSize.width), imageHeight: Int(imageSize.height),
            intrinsics: [i[0], i[1], i[2]].flatMap { [$0.x, $0.y, $0.z] },
            transform: [t[0], t[1], t[2], t[3]].flatMap { [$0.x, $0.y, $0.z, $0.w] })
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

/// Owns the AR session. ARKit is used only for tracking and geometry (depth, raycasts); every recognition task
/// stays with Meta's models on the Mac (HACKATHON.md, Approved Exceptions, 2026-10-27).
final class ARGuideController: NSObject, ObservableObject, ARSessionDelegate {
    static let maxImageSide: CGFloat = 1600
    static let guessDistance: Float = 0.6

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    @Published private(set) var marker: MarkerState?
    @Published private(set) var trackingIssue: String?

    var currentStep: Int? { didSet { updateMarker() } }
    private(set) var anchors: [StepAnchor] = []
    private var displayLink: CADisplayLink?
    private let ciContext = CIContext()

    var hasLiDAR: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    func start() {
        let configuration = ARWorldTrackingConfiguration()
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
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    func pause() {
        arView.session.pause()
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: Capture

    /// The current frame, or nil while tracking is not ready.
    func capture() -> CapturedFrame? {
        guard let frame = arView.session.currentFrame else { return nil }
        let pixelBuffer = frame.capturedImage
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        // With the interface locked to landscape right, the sensor image is already upright.
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1, Self.maxImageSide / max(size.width, size.height))
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(
                of: image, colorSpace: space,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8])
        else { return nil }
        return CapturedFrame(jpeg: jpeg, imageSize: size, intrinsics: frame.camera.intrinsics,
                             cameraTransform: frame.camera.transform, depth: Self.copyDepth(frame))
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
    func place(_ plan: GuidePlan, from capture: CapturedFrame) {
        anchors = plan.steps.map { step in
            let center = step.markerPoint
            let (control, distance, precise) = locate(center, capture)
            var radius: Float = 0.025
            if let box = step.box, step.boxMethod == "point" || step.boxMethod == "fallback" {
                let pixels = max(box.width * capture.imageSize.width, box.height * capture.imageSize.height) / 2
                radius = min(max(CameraGeometry.meters(pixels: pixels, depth: distance, intrinsics: capture.intrinsics), 0.012), 0.08)
            }
            let label = step.setTo?.point.map { locate($0, capture).position }
            return StepAnchor(control: control, radius: radius, label: label, precise: precise)
        }
        updateMarker()
    }

    func clear() {
        anchors = []
        currentStep = nil
    }

    /// LiDAR depth at the point first, then a raycast from the capture-time camera, then a fixed-distance guess.
    private func locate(_ point: NormalizedPoint, _ capture: CapturedFrame) -> (position: SIMD3<Float>, depth: Float, precise: Bool) {
        let pixel = CGPoint(x: point.x * capture.imageSize.width, y: point.y * capture.imageSize.height)
        if let depth = capture.depth?.depth(atNormalized: CGPoint(x: point.x, y: point.y)) {
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

    // MARK: ARSessionDelegate

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
