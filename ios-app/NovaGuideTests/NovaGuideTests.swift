import CoreGraphics
import simd
import XCTest
@testable import NovaGuide

final class CameraGeometryTests: XCTestCase {
    // fx = fy = 1000, principal point (960, 720): a 1920x1440 sensor image.
    let intrinsics = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 1000, 0), SIMD3(960, 720, 1)))

    func testCenterPixelLiesStraightAhead() {
        let point = CameraGeometry.cameraPoint(pixel: CGPoint(x: 960, y: 720), depth: 0.5, intrinsics: intrinsics)
        XCTAssertEqual(point, SIMD3(0, 0, -0.5))
    }

    func testImageAxesMapToCameraAxes() {
        // Right of center in the image is +x; below center is -y (camera y points up).
        let point = CameraGeometry.cameraPoint(pixel: CGPoint(x: 1060, y: 820), depth: 2, intrinsics: intrinsics)
        XCTAssertEqual(point.x, 0.2, accuracy: 1e-6)
        XCTAssertEqual(point.y, -0.2, accuracy: 1e-6)
        XCTAssertEqual(point.z, -2, accuracy: 1e-6)
    }

    func testWorldPointUsesTheCaptureTimeCamera() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(1, 2, 3, 1)  // camera moved, not rotated
        let world = CameraGeometry.worldPoint(pixel: CGPoint(x: 960, y: 720), depth: 1, intrinsics: intrinsics,
                                              cameraTransform: transform)
        XCTAssertEqual(world, SIMD3(1, 2, 2))
    }

    func testWorldRayIsUnitLengthFromTheCamera() {
        let ray = CameraGeometry.worldRay(pixel: CGPoint(x: 0, y: 0), intrinsics: intrinsics, cameraTransform: matrix_identity_float4x4)
        XCTAssertEqual(ray.origin, SIMD3(0, 0, 0))
        XCTAssertEqual(simd_length(ray.direction), 1, accuracy: 1e-5)
        XCTAssertLessThan(ray.direction.x, 0)
        XCTAssertGreaterThan(ray.direction.y, 0)
    }

    func testMetersFromPixels() {
        XCTAssertEqual(CameraGeometry.meters(pixels: 50, depth: 0.4, intrinsics: intrinsics), 0.02, accuracy: 1e-6)
    }
}

final class DepthSampleTests: XCTestCase {
    func testMedianIgnoresHolesAndOutliers() {
        var values = [Float](repeating: 1.0, count: 25)
        values[0] = 0  // hole
        values[1] = 9  // outlier
        let sample = DepthSample(width: 5, height: 5, values: values)
        XCTAssertEqual(sample.depth(atNormalized: CGPoint(x: 0.5, y: 0.5)), 1.0)
    }

    func testNoValidDepthGivesNil() {
        let sample = DepthSample(width: 2, height: 2, values: [0, 0, .nan, 0])
        XCTAssertNil(sample.depth(atNormalized: CGPoint(x: 0.5, y: 0.5)))
    }
}

final class GuidePlanTests: XCTestCase {
    func testDecodesTheServerAnswer() throws {
        let json = """
        {"device": {"type": "washing machine", "brand": "Maytag"}, "safe": true, "safetyNote": "", "uncertainty": "",
         "frame": {"width": 1600, "height": 1200}, "served": ["muse-spark-1.3", "sam-3.1"], "timings": {"plan": 4.1},
         "steps": [
          {"instruction": "Sıcaklığı sıcağa çevir.", "target": "temperature knob", "success": "pointer at hot",
           "point": {"x": 0.21, "y": 0.41}, "box": {"x1": 0.18, "y1": 0.36, "x2": 0.24, "y2": 0.46, "confidence": 0.91},
           "boxMethod": "point", "setTo": {"label": "hot", "meaning": "sıcak", "point": {"x": 0.26, "y": 0.3}}},
          {"instruction": "Başlat.", "target": "start button", "success": "", "point": {"x": 0.8, "y": 0.4},
           "box": null, "boxMethod": "none", "setTo": null}
         ]}
        """
        let plan = try JSONDecoder().decode(GuidePlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.deviceLabel, "Maytag · washing machine")
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].markerPoint.x, 0.21, accuracy: 1e-9)  // the box center
        XCTAssertEqual(plan.steps[0].setTo?.meaning, "sıcak")
        XCTAssertEqual(plan.steps[1].markerPoint, NormalizedPoint(x: 0.8, y: 0.4))  // no box: Spark's point
    }

    func testAWeakFallbackBoxIsNotUsedForTheMarker() {
        let step = GuideStep(instruction: "", target: "", success: "", point: NormalizedPoint(x: 0.1, y: 0.1),
                             box: NormalizedBox(x1: 0.5, y1: 0.5, x2: 0.7, y2: 0.7), boxMethod: "fallback_weak", setTo: nil)
        XCTAssertEqual(step.markerPoint, NormalizedPoint(x: 0.1, y: 0.1))
    }
}

final class CropGeometryTests: XCTestCase {
    let image = CGSize(width: 1920, height: 1440)

    func testCropIsAboutThreeKnobDiametersAroundTheControl() {
        guard case .crop(let rect) = CropGeometry.crop(control: CGPoint(x: 960, y: 720), radius: 80, label: nil, imageSize: image) else {
            return XCTFail("expected a crop")
        }
        XCTAssertEqual(rect, CGRect(x: 704, y: 464, width: 512, height: 512))
    }

    func testCropReachesTheDialsTargetLabel() {
        guard case .crop(let rect) = CropGeometry.crop(control: CGPoint(x: 960, y: 720), radius: 80,
                                                       label: CGPoint(x: 960, y: 400), imageSize: image) else {
            return XCTFail("expected a crop")
        }
        XCTAssertTrue(rect.contains(CGPoint(x: 960, y: 400)))
    }

    func testCropIsClampedToTheImage() {
        guard case .crop(let rect) = CropGeometry.crop(control: CGPoint(x: 100, y: 100), radius: 80, label: nil, imageSize: image) else {
            return XCTFail("expected a crop")
        }
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.minY, 0)
    }

    func testAFarAwayControlIsTooSmallAndAnOffScreenOneIsReported() {
        XCTAssertEqual(CropGeometry.crop(control: CGPoint(x: 960, y: 720), radius: 20, label: nil, imageSize: image), .tooSmall)
        XCTAssertEqual(CropGeometry.crop(control: CGPoint(x: -5, y: 720), radius: 80, label: nil, imageSize: image), .offScreen)
    }
}

final class StepCheckTests: XCTestCase {
    func testDecodesAVerifyAnswer() throws {
        let json = #"{"status": "not_done", "observed": "warm", "correction": "Biraz sağa.", "seconds": 3.1, "served": ["muse-spark-1.3"]}"#
        let check = try JSONDecoder().decode(StepCheck.self, from: Data(json.utf8))
        XCTAssertEqual(check.status, .notDone)
        XCTAssertEqual(check.correction, "Biraz sağa.")
    }

    func testStepsAreVerifiableUnlessTheServerSaysNot() throws {
        let json = #"{"instruction": "", "target": "", "success": "", "point": {"x": 0, "y": 0}, "box": null, "boxMethod": "none", "setTo": null}"#
        XCTAssertTrue(try JSONDecoder().decode(GuideStep.self, from: Data(json.utf8)).isVerifiable)
        let pressOnly = json.replacingOccurrences(of: #""setTo": null"#, with: #""setTo": null, "verifiable": false"#)
        XCTAssertFalse(try JSONDecoder().decode(GuideStep.self, from: Data(pressOnly.utf8)).isVerifiable)
    }
}
