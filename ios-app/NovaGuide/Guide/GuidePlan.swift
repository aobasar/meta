import Foundation

/// The plan the Nova server returns for one frame and one question (web-prototype/guide.py).
/// Points and boxes are normalized to the frame that was sent: 0-1, origin top-left.
struct GuidePlan: Decodable, Equatable {
    struct Device: Decodable, Equatable {
        var type: String
        var brand: String
    }

    struct FrameSize: Decodable, Equatable {
        var width: Int
        var height: Int
    }

    var device: Device
    var safe: Bool
    var safetyNote: String
    var uncertainty: String
    /// The language Spark wrote the plan in, and the language printed on the device (an older server sends neither).
    var language: String? = nil
    var labelLanguage: String? = nil
    var frame: FrameSize
    /// False on the first part of a streamed plan: the steps, before the controls are located (an older server
    /// sends one located plan without this field).
    var located: Bool? = nil
    /// Nova asks this before it plans; such a plan has no steps.
    var question: Question? = nil
    var steps: [GuideStep]
    var served: [String]
    var recording: String?

    var isLocated: Bool { located ?? true }

    /// One thing Nova needs to know: a setting to pick, the device to confirm, or a fact the photo can't show.
    struct Question: Decodable, Equatable {
        struct Option: Decodable, Equatable, Identifiable {
            /// Printed on the device; empty for a plain answer such as "Yes".
            var label: String
            /// What the label means, or the plain answer, in the user's language.
            var meaning: String

            var id: String { label + meaning }
            var title: String { label.isEmpty ? meaning : label }
            var subtitle: String? { label.isEmpty || meaning.isEmpty ? nil : meaning }
            var answer: String { label.isEmpty ? meaning : "\(label) (\(meaning))" }
        }

        var kind: String
        var text: String
        var options: [Option]
    }

    /// "Maytag · washing machine", or just the type when no brand was read.
    var deviceLabel: String {
        device.brand.isEmpty ? device.type : "\(device.brand) · \(device.type)"
    }
}

struct NormalizedPoint: Decodable, Equatable {
    var x: Double
    var y: Double
}

struct NormalizedBox: Decodable, Equatable {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double
    var confidence: Double?

    var center: NormalizedPoint { NormalizedPoint(x: (x1 + x2) / 2, y: (y1 + y2) / 2) }
    var width: Double { x2 - x1 }
    var height: Double { y2 - y1 }
}

struct GuideStep: Decodable, Equatable {
    struct SetTo: Decodable, Equatable {
        /// The label printed on the device, as read from the photo.
        var label: String
        /// What the label means, in the user's language.
        var meaning: String
        var point: NormalizedPoint?
    }

    var instruction: String
    /// One line in the user's language that helps find the control or tell the step is done.
    var detail: String? = nil
    var target: String
    /// What a close-up of the control shows once the step is done; used by step verification.
    var success: String
    var point: NormalizedPoint
    var box: NormalizedBox?
    var boxMethod: String
    var setTo: SetTo?
    /// False when a close-up can't show the result (a momentary press); such steps are not checked.
    var verifiable: Bool? = nil

    var isVerifiable: Bool { verifiable ?? true }

    /// Where the marker goes: the SAM box's center when SAM found a usable box, otherwise Spark's point.
    var markerPoint: NormalizedPoint {
        if let box, boxMethod == "point" || boxMethod == "fallback" { return box.center }
        return point
    }
}

/// Muse Spark's check of one step on a close-up of its control.
struct StepCheck: Decodable, Equatable {
    enum Status: String, Decodable {
        case done
        case notDone = "not_done"
        case unsure
    }

    var status: Status
    var observed: String
    var correction: String
    /// "too_small" when the server judged the close-up too small to read.
    var reason: String?
    var recording: String?
}

struct ServerError: Decodable {
    struct Detail: Decodable {
        var kind: String?
        var message: String
    }

    var error: Detail
}
