import CoreGraphics
import ImageIO
import simd

/// Pure camera math, kept apart from ARKit so it can be unit-tested.
///
/// ARKit's camera space: x right, y up, z toward the viewer (the camera looks down -z). Image pixels: origin
/// top-left, x right, y down, in the captured image's resolution (the sensor's landscape orientation).
enum CameraGeometry {
    /// The world-space point at `depth` meters in front of the camera, along the ray through `pixel`.
    static func worldPoint(pixel: CGPoint, depth: Float, intrinsics: simd_float3x3, cameraTransform: simd_float4x4) -> SIMD3<Float> {
        let local = cameraPoint(pixel: pixel, depth: depth, intrinsics: intrinsics)
        let world = cameraTransform * SIMD4<Float>(local, 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    /// The camera-space point at `depth` meters (distance along -z) through `pixel`.
    static func cameraPoint(pixel: CGPoint, depth: Float, intrinsics: simd_float3x3) -> SIMD3<Float> {
        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]
        let x = (Float(pixel.x) - cx) / fx
        let y = (Float(pixel.y) - cy) / fy
        return SIMD3<Float>(x * depth, -y * depth, -depth)
    }

    /// A world-space ray (origin, unit direction) through `pixel`, for raycasts when no depth is known.
    static func worldRay(pixel: CGPoint, intrinsics: simd_float3x3, cameraTransform: simd_float4x4) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let origin = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let target = worldPoint(pixel: pixel, depth: 1, intrinsics: intrinsics, cameraTransform: cameraTransform)
        return (origin, simd_normalize(target - origin))
    }

    /// The physical size (meters) that `pixels` span at `depth`.
    static func meters(pixels: Double, depth: Float, intrinsics: simd_float3x3) -> Float {
        Float(pixels) / intrinsics[0][0] * depth
    }
}

/// How the sensor image (always landscape right) is turned so the frame sent to Spark is upright on screen.
/// Spark's points come back in the upright frame; anchoring needs them in the sensor image again.
enum FrameOrientation: String, Equatable {
    case landscapeRight, portrait, landscapeLeft

    /// The Core Image orientation that turns the sensor image upright.
    var imageOrientation: CGImagePropertyOrientation {
        switch self {
        case .landscapeRight: .up
        case .portrait: .right
        case .landscapeLeft: .down
        }
    }

    func uprightSize(_ sensor: CGSize) -> CGSize {
        self == .portrait ? CGSize(width: sensor.height, height: sensor.width) : sensor
    }

    /// A normalized point (0-1, top-left) in the upright frame, in the sensor image.
    func sensorPoint(_ point: CGPoint) -> CGPoint {
        switch self {
        case .landscapeRight: point
        case .portrait: CGPoint(x: point.y, y: 1 - point.x)
        case .landscapeLeft: CGPoint(x: 1 - point.x, y: 1 - point.y)
        }
    }
}

/// A copy of one frame's LiDAR depth map (meters), so depth can be read after the frame is gone.
struct DepthSample {
    var width: Int
    var height: Int
    var values: [Float]

    /// The median valid depth in a small window around a normalized image point (0-1, top-left); nil if none.
    func depth(atNormalized point: CGPoint, radius: Int = 2) -> Float? {
        guard width > 0, height > 0 else { return nil }
        let cx = min(max(Int(point.x * CGFloat(width)), 0), width - 1)
        let cy = min(max(Int(point.y * CGFloat(height)), 0), height - 1)
        var window: [Float] = []
        for y in max(cy - radius, 0)...min(cy + radius, height - 1) {
            for x in max(cx - radius, 0)...min(cx + radius, width - 1) {
                let value = values[y * width + x]
                if value.isFinite && value > 0.05 { window.append(value) }
            }
        }
        guard !window.isEmpty else { return nil }
        window.sort()
        return window[window.count / 2]
    }
}

/// The close-up sent for step verification: the control with room around it for the printed labels, and the dial's
/// target label when there is one. Prototype crops of about 3 knob diameters scored 20 of 21 (docs/goster-bana.md).
enum CropGeometry {
    static let minSide: CGFloat = 200  // pixels of the captured image; smaller can't show a pointer reliably
    static let paddingRadii: CGFloat = 3.2  // half the crop's side, in control radii

    enum Result: Equatable {
        case crop(CGRect)
        case offScreen
        case tooSmall
    }

    /// A square crop in image pixels (origin top-left), clamped to the image.
    static func crop(control: CGPoint, radius: CGFloat, label: CGPoint?, imageSize: CGSize) -> Result {
        let bounds = CGRect(origin: .zero, size: imageSize)
        guard bounds.contains(control) else { return .offScreen }
        var half = radius * paddingRadii
        if let label {
            half = max(half, hypot(label.x - control.x, label.y - control.y) + radius * 1.2)
        }
        let rect = CGRect(x: control.x - half, y: control.y - half, width: half * 2, height: half * 2).intersection(bounds)
        guard rect.width >= minSide, rect.height >= minSide else { return .tooSmall }
        return .crop(rect.integral)
    }
}
