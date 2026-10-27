import Foundation

/// Short spoken commands, matched in the transcript on the phone (plain text search, no model call). Anything else is
/// a question for Nova.
enum VoiceCommand: CaseIterable {
    case newQuestion, back, repeatStep, skip, done

    /// Phrases per command, Turkish and English. Checked in `allCases` order, so "yeni soru" wins over anything shorter.
    private var phrases: [String] {
        switch self {
        case .newQuestion: ["yeni soru", "baştan başla", "baştan", "new question", "start over"]
        case .back: ["geri dön", "geri", "önceki", "go back", "back", "previous"]
        case .repeatStep: ["tekrarla", "tekrar söyle", "bir daha", "tekrar", "repeat", "say again", "again"]
        case .skip: ["geç", "atla", "sonraki", "skip", "next"]
        case .done: ["yaptım", "tamam", "bitti", "oldu", "hazır", "done", "ok", "okay", "finished", "did it"]
        }
    }

    static let maxWords = 4  // a longer utterance is a question, even if it contains "tamam"
    /// Words that make an utterance a question ("ne yaptım?"), whatever else it contains.
    static let questionWords: Set<String> = [
        "ne", "neden", "nasıl", "hangi", "hangisi", "nerede", "nereye", "kaç", "mi", "mı", "mu", "mü",
        "what", "why", "how", "which", "where", "when",
    ]

    static func match(_ transcript: String) -> VoiceCommand? {
        let words = normalize(transcript)
        guard !words.isEmpty, words.count <= maxWords, questionWords.isDisjoint(with: words) else { return nil }
        let text = " " + words.joined(separator: " ") + " "
        return allCases.first { command in command.phrases.contains { text.contains(" \(normalize($0).joined(separator: " ")) ") } }
    }

    static func normalize(_ text: String) -> [String] {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }
}
