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
    /// The task goes on past what this photo shows (the next screen, a panel that opens), and the way as Spark expects it.
    var continues: Bool? = nil
    var remaining: String? = nil
    /// What the camera shows once the whole task is finished; checked after the last step.
    var goal: String? = nil
    /// Nova asks this before it plans; such a plan has no steps.
    var question: Question? = nil
    /// Kokobubu needs to see something else first; such a plan has no steps.
    var showRequest: ShowRequest? = nil
    /// What this photo told about the problem, sent back with the next photo.
    var finding: String? = nil
    var steps: [GuideStep]
    var served: [String]
    var recording: String?

    var isLocated: Bool { located ?? true }
    var goesOn: Bool { continues ?? false }

    /// "Show me the mouse": the next thing to point the camera at, and what Kokobubu will check there.
    struct ShowRequest: Decodable, Equatable {
        var what: String
        var why: String
    }

    /// One thing Nova needs to know: a setting to pick, the device to confirm, or a fact the photo can't show.
    struct Question: Decodable, Equatable {
        struct Option: Decodable, Equatable, Identifiable {
            /// Printed on the device; empty for a plain answer such as "Yes".
            var label: String
            /// What the label means, or the plain answer, in the user's language.
            var meaning: String
            /// The control's own color as "#RRGGBB", when it has a distinctive one.
            var color: String?

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
    /// What the camera shows once the step is done; used by step verification.
    var success: String
    var point: NormalizedPoint
    var box: NormalizedBox?
    var boxMethod: String
    var setTo: SetTo?
    /// Where a photo can show the result: "close_up", "whole_view" or "none". An older server sends only `verifiable`.
    var check: String? = nil
    var verifiable: Bool? = nil

    /// How the hand moves the control; an older server sends none, and Spark says "unknown" when it can't tell.
    var motion: String? = nil

    /// False when nothing visible changes (a momentary press); such steps are not checked.
    var isVerifiable: Bool { check.map { $0 != "none" } ?? verifiable ?? true }
    /// The result shows away from the control, so a close-up can't show it.
    var checksWholeView: Bool { check == "whole_view" }

    enum Motion: String {
        case press
        case turnClockwise = "turn_clockwise"
        case turnCounterclockwise = "turn_counterclockwise"
        case pull, push
        case swipeLeft = "swipe_left"
        case swipeRight = "swipe_right"
        case swipeUp = "swipe_up"
        case swipeDown = "swipe_down"
        case dragLeft = "drag_left"
        case dragRight = "drag_right"
        case dragUp = "drag_up"
        case dragDown = "drag_down"
        /// The app's own, when the plan names no motion: the hand still shows where. The server never sends it.
        case point

        /// The way the finger moves on the screen (y down), for a swipe or a drag.
        var swipe: CGVector? {
            switch self {
            case .swipeLeft, .dragLeft: CGVector(dx: -1, dy: 0)
            case .swipeRight, .dragRight: CGVector(dx: 1, dy: 0)
            case .swipeUp, .dragUp: CGVector(dx: 0, dy: -1)
            case .swipeDown, .dragDown: CGVector(dx: 0, dy: 1)
            default: nil
            }
        }

        /// The finger presses and holds before it moves.
        var holds: Bool { [.dragLeft, .dragRight, .dragUp, .dragDown].contains(self) }

        var title: String {
            switch self {
            case .press: String(localized: "Press", bundle: .ui)
            case .turnClockwise: String(localized: "Turn clockwise", bundle: .ui)
            case .turnCounterclockwise: String(localized: "Turn counterclockwise", bundle: .ui)
            case .pull: String(localized: "Pull toward you", bundle: .ui)
            case .push: String(localized: "Push in", bundle: .ui)
            case .swipeLeft: String(localized: "Swipe left", bundle: .ui)
            case .swipeRight: String(localized: "Swipe right", bundle: .ui)
            case .swipeUp: String(localized: "Swipe up", bundle: .ui)
            case .swipeDown: String(localized: "Swipe down", bundle: .ui)
            case .dragLeft: String(localized: "Hold and drag left", bundle: .ui)
            case .dragRight: String(localized: "Hold and drag right", bundle: .ui)
            case .dragUp: String(localized: "Hold and drag up", bundle: .ui)
            case .dragDown: String(localized: "Hold and drag down", bundle: .ui)
            case .point: ""
            }
        }

        var symbol: String {
            switch self {
            case .press: "hand.tap"
            case .turnClockwise: "arrow.clockwise"
            case .turnCounterclockwise: "arrow.counterclockwise"
            case .pull: "arrow.up.left.and.arrow.down.right"
            case .push: "arrow.down.right.and.arrow.up.left"
            case .swipeLeft, .dragLeft: "arrow.left"
            case .swipeRight, .dragRight: "arrow.right"
            case .swipeUp, .dragUp: "arrow.up"
            case .swipeDown, .dragDown: "arrow.down"
            case .point: "hand.point.up.left"
            }
        }
    }

    var motionKind: Motion? { motion.flatMap(Motion.init(rawValue:)).flatMap { $0 == .point ? nil : $0 } }

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
        /// Only for a whole task: the device is still working on it.
        case inProgress = "in_progress"
    }

    var status: Status
    var observed: String
    var correction: String
    /// What is now set, said after a passed check; empty or missing when the model gave none.
    var confirmation: String?
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
