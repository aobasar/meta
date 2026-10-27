import CoreGraphics
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
