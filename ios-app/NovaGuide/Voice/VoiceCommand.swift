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

    // The experimental languages list "ok" too, so saying it doesn't switch their speakers to English.
    private var spanish: [String] {
        switch self {
        case .newQuestion: ["nueva pregunta", "empezar de nuevo"]
        case .back: ["volver", "atrás", "anterior"]
        case .repeatStep: ["repite", "otra vez", "de nuevo"]
        case .skip: ["saltar", "siguiente"]
        case .wrong: ["está mal", "incorrecto", "eso no"]
        case .done: ["listo", "hecho", "ya está", "terminé", "ok", "okay"]
        }
    }

    private var mandarin: [String] {
        switch self {
        case .newQuestion: ["新问题", "重新开始"]
        case .back: ["返回", "上一步", "回去"]
        case .repeatStep: ["重复", "再说一遍", "再来一次"]
        case .skip: ["跳过", "下一步"]
        case .wrong: ["不对", "错了", "不是这个"]
        case .done: ["好了", "完成了", "做好了", "可以了", "好的", "ok", "okay"]
        }
    }

    private var hindi: [String] {
        switch self {
        case .newQuestion: ["नया सवाल", "फिर से शुरू"]
        case .back: ["वापस जाओ", "वापस", "पिछला"]
        case .repeatStep: ["दोहराओ", "फिर से बोलो", "फिर से"]
        case .skip: ["छोड़ो", "आगे बढ़ो", "अगला"]
        case .wrong: ["गलत", "ग़लत", "यह नहीं"]
        case .done: ["हो गया", "कर लिया", "ठीक है", "तैयार", "ok", "okay"]
        }
    }

    private var arabic: [String] {
        switch self {
        case .newQuestion: ["سؤال جديد", "ابدأ من جديد"]
        case .back: ["ارجع", "رجوع", "السابق"]
        case .repeatStep: ["كرر", "أعد", "مرة أخرى"]
        case .skip: ["تخطى", "التالي"]
        case .wrong: ["خطأ", "غلط", "ليس هذا"]
        case .done: ["تم", "انتهيت", "حسنا", "جاهز", "ok", "okay"]
        }
    }

    private var portuguese: [String] {
        switch self {
        case .newQuestion: ["nova pergunta", "começar de novo"]
        case .back: ["voltar", "volta", "anterior"]
        case .repeatStep: ["repete", "repita", "de novo", "outra vez"]
        case .skip: ["pular", "próximo"]
        case .wrong: ["errado", "isso não", "incorreto"]
        case .done: ["pronto", "feito", "terminei", "já fiz", "ok", "okay"]
        }
    }

    private func phrases(in language: String) -> [String] {
        switch language {
        case "Turkish": turkish
        case "English": english
        case "Spanish": spanish
        case "Mandarin Chinese": mandarin
        case "Hindi": hindi
        case "Arabic": arabic
        case "Portuguese": portuguese
        default: []
        }
    }

    private static let languages = ["Turkish", "English", "Spanish", "Mandarin Chinese", "Hindi", "Arabic", "Portuguese"]

    static let maxWords = 4  // a longer utterance is a question, even if it contains "tamam"
    /// Words that make an utterance a question ("ne yaptım?"), whatever else it contains.
    static let questionWords = normalized([
        "ne", "neden", "nasıl", "hangi", "hangisi", "nerede", "nereye", "kaç", "mi", "mı", "mu", "mü",
        "what", "why", "how", "which", "where", "when",
        "qué", "cómo", "cuál", "dónde", "cuándo", "quién",
        "什么", "为什么", "怎么", "哪个", "哪里",
        "क्या", "कैसे", "क्यों", "कौन", "कहाँ", "कब",
        "ماذا", "كيف", "لماذا", "أين", "متى", "هل", "ما",
        "quê", "como", "qual", "onde", "quando",
    ])

    static func match(_ transcript: String) -> VoiceCommand? { matchWithLanguage(transcript)?.command }

    /// The command and the language it was said in, for automatic language. A phrase two languages share counts as
    /// `preferring`, the language spoken now ("anterior" doesn't switch Portuguese to Spanish).
    static func matchWithLanguage(_ transcript: String, preferring: String? = nil) -> (command: VoiceCommand, language: String)? {
        let words = normalize(transcript)
        guard !words.isEmpty, words.count <= maxWords, questionWords.isDisjoint(with: words) else { return nil }
        let text = " " + words.joined(separator: " ") + " "
        func said(_ phrases: [String]) -> Bool { phrases.contains { text.contains(" \(normalize($0).joined(separator: " ")) ") } }
        let order = (preferring.map { [$0] } ?? []) + languages.filter { $0 != preferring }
        for command in allCases {
            for language in order where said(command.phrases(in: language)) {
                return (command, language)
            }
        }
        return nil
    }

    /// An answer to "Did this solve it?": true, false, or nil when the sentence says something else (what happened).
    static func confirmation(_ transcript: String) -> Bool? {
        let words = normalize(transcript)
        guard !words.isEmpty, words.count <= maxWords else { return nil }
        let no = normalized(["hayır", "değil", "olmadı", "çözülmedi", "no", "not", "nope", "tampoco", "não", "nao",
                             "不是", "没有", "没解决", "不行", "不对", "नहीं", "नही", "لا", "ليس", "لم"])
        let yes = normalized(["evet", "çözüldü", "oldu", "tamam", "yes", "yeah", "solved", "worked", "ok", "okay",
                              "sí", "si", "funcionó", "resuelto", "listo", "sim", "funcionou", "resolvido", "pronto",
                              "是", "是的", "对", "好了", "解决了", "可以了", "हाँ", "हां", "हल", "ठीक", "نعم", "أجل", "حسنا", "تم"])
        if !no.isDisjoint(with: words) { return false }
        return yes.isDisjoint(with: words) ? nil : true
    }

    /// Dotless ı folds into i: Turkish lowercasing turns a capital I into ı, in "Incorrecto" as much as in "Isso".
    static func normalize(_ text: String) -> [String] {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    private static func normalized(_ words: [String]) -> Set<String> { Set(words.flatMap(normalize)) }
}
