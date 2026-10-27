import Foundation

/// Nova's text marks words copied from the device with « » (web-prototype/guide.py, MARKING_RULE): the screen shows
/// them in quotes, and the voice reads them in the labels' language, the rest in the user's.
enum GuideText {
    struct Segment: Equatable {
        var text: String
        /// A word or phrase printed on the device.
        var isLabel: Bool
    }

    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "«") {
            guard let close = rest[open...].firstIndex(of: "»") else { break }  // unbalanced: plain text
            if open > rest.startIndex { segments.append(Segment(text: String(rest[..<open]), isLabel: false)) }
            let label = rest[rest.index(after: open)..<close]
            if !label.isEmpty { segments.append(Segment(text: String(label), isLabel: true)) }
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { segments.append(Segment(text: String(rest), isLabel: false)) }
        return segments
    }

    /// For the screen: «warm» becomes “warm”.
    static func display(_ text: String) -> String {
        segments(text).map { $0.isLabel ? "“\($0.text)”" : $0.text }.joined()
    }
}
