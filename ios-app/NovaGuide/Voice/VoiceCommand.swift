import Foundation

/// Short spoken commands, matched in the transcript on the phone (plain text search, no model call). Anything else is
/// a question for Nova.
enum VoiceCommand: CaseIterable {
    case newQuestion, back, repeatStep, skip, wrong, done

    /// Phrases per command and language. Checked in `allCases` order, so "yeni soru" wins over anything shorter.
    private var turkish: [String] {
        switch self {
        case .newQuestion: ["yeni soru", "baştan başla", "baştan"]
        case .back: ["geri dön", "geri", "önceki"]
        case .repeatStep: ["tekrarla", "tekrar söyle", "bir daha", "tekrar"]
        case .skip: ["geç", "atla", "sonraki"]
        case .wrong: ["yanlış", "bu değil", "hatalı"]
        case .done: ["yaptım", "tamam", "bitti", "oldu", "hazır"]
        }
    }

    private var english: [String] {
        switch self {
        case .newQuestion: ["new question", "start over"]
        case .back: ["go back", "back", "previous"]
        case .repeatStep: ["repeat", "say again", "again"]
        case .skip: ["skip", "next"]
        case .wrong: ["wrong", "not this", "incorrect"]
        case .done: ["done", "ok", "okay", "finished", "did it"]
        }
    }

    static let maxWords = 4  // a longer utterance is a question, even if it contains "tamam"
    /// Words that make an utterance a question ("ne yaptım?"), whatever else it contains.
    static let questionWords: Set<String> = [
        "ne", "neden", "nasıl", "hangi", "hangisi", "nerede", "nereye", "kaç", "mi", "mı", "mu", "mü",
        "what", "why", "how", "which", "where", "when",
    ]

    static func match(_ transcript: String) -> VoiceCommand? { matchWithLanguage(transcript)?.command }

    /// The command and the language it was said in ("Turkish" or "English"), for automatic language.
    static func matchWithLanguage(_ transcript: String) -> (command: VoiceCommand, language: String)? {
        let words = normalize(transcript)
        guard !words.isEmpty, words.count <= maxWords, questionWords.isDisjoint(with: words) else { return nil }
        let text = " " + words.joined(separator: " ") + " "
        func said(_ phrases: [String]) -> Bool { phrases.contains { text.contains(" \(normalize($0).joined(separator: " ")) ") } }
        for command in allCases {
            if said(command.turkish) { return (command, "Turkish") }
            if said(command.english) { return (command, "English") }
        }
        return nil
    }

    /// An answer to "Did this solve it?": true, false, or nil when the sentence says something else (what happened).
    static func confirmation(_ transcript: String) -> Bool? {
        let words = normalize(transcript)
        guard !words.isEmpty, words.count <= maxWords else { return nil }
        let no: Set = ["hayır", "değil", "olmadı", "çözülmedi", "no", "not", "nope"]
        let yes: Set = ["evet", "çözüldü", "oldu", "tamam", "yes", "yeah", "solved", "worked", "ok", "okay"]
        if !no.isDisjoint(with: words) { return false }
        return yes.isDisjoint(with: words) ? nil : true
    }

    static func normalize(_ text: String) -> [String] {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }
}
