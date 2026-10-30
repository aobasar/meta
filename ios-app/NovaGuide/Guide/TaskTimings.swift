import Foundation

/// Settings › Speed test: how long each part of the current task took, measured on the phone, so the network and the
/// upload are included: this is the wait the user feels.
struct TaskTimings: Equatable {
    var transcript: Double?
    /// The transcript came over the live route (measured from the end of speech).
    var liveVoice = false
    var steps: Double?
    var markers: Double?
    var check: Double?
    var answer: Double?
    /// The Spark setting in use, for example "Meta Minimal".
    var setting = ""

    var isEmpty: Bool { [transcript, steps, markers, check, answer].allSatisfy { $0 == nil } }

    /// "Voice 1.9 s · Steps 3.4 s · Markers 7.1 s · Check 1.6 s · Meta Minimal"
    var summary: String {
        let parts: [(String, Double?)] = [
            (liveVoice ? String(localized: "Live voice") : String(localized: "Voice"), transcript),
            (String(localized: "Steps"), steps),
            (String(localized: "Markers"), markers),
            (String(localized: "Check"), check),
            (String(localized: "Answer"), answer),
        ]
        let times = parts.compactMap { title, seconds -> String? in
            guard let seconds else { return nil }
            let number = seconds.formatted(.number.precision(.fractionLength(1)))
            return "\(title) " + String(localized: "\(number) s")
        }
        return (times + (setting.isEmpty ? [] : [setting])).joined(separator: " · ")
    }
}
