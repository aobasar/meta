import Foundation
import simd

/// The next screen's plan, asked for as soon as the last step's check passes, so Continue doesn't wait for the models.
@MainActor
final class PreparedPlan {
    static let maxAge: TimeInterval = 30
    static let maxMeters: Float = 0.4
    static let maxTurn: Float = .pi / 4

    let capture: CapturedFrame
    let correction: GuideClient.Correction
    let start: Int
    let asked = Date()
    var task: Task<GuidePlan, Error>?
    private(set) var isReady = false
    private var steps: GuidePlan?
    private var onSteps: ((GuidePlan) -> Void)?

    init(capture: CapturedFrame, correction: GuideClient.Correction, start: Int) {
        self.capture = capture
        self.correction = correction
        self.start = start
    }

    /// The plan's steps came, before its controls are located.
    func received(steps: GuidePlan) {
        self.steps = steps
        onSteps?(steps)
    }

    func finished() {
        isReady = true
    }

    /// The whole plan for the screen that was waiting on it: the steps as soon as they are here, then the located plan.
    func result(onSteps: @escaping (GuidePlan) -> Void) async throws -> GuidePlan {
        if let steps { onSteps(steps) } else { self.onSteps = onSteps }
        guard let task else { throw CancellationError() }
        // Home or a new task cancels the waiting screen, and with it the plan.
        let plan = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return plan
    }

    /// Whether what the plan saw still stands: the user soon went on, from about the same place.
    nonisolated static func isFresh(age: TimeInterval, moved: Float, turned: Float) -> Bool {
        age <= maxAge && moved <= maxMeters && turned <= maxTurn
    }

    /// How far a camera moved and turned between two poses.
    nonisolated static func change(from old: simd_float4x4, to new: simd_float4x4) -> (moved: Float, turned: Float) {
        let oldSpot = SIMD3<Float>(old.columns.3.x, old.columns.3.y, old.columns.3.z)
        let newSpot = SIMD3<Float>(new.columns.3.x, new.columns.3.y, new.columns.3.z)
        let oldAim = SIMD3<Float>(old.columns.2.x, old.columns.2.y, old.columns.2.z)
        let newAim = SIMD3<Float>(new.columns.2.x, new.columns.2.y, new.columns.2.z)
        let cosine = simd_dot(simd_normalize(oldAim), simd_normalize(newAim))
        return (simd_distance(oldSpot, newSpot), acos(min(max(cosine, -1), 1)))
    }
}
