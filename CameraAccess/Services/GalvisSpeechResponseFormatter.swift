import Foundation

struct GalvisSpeechResponseFormatter {
    static let directSpeechLimit = 180
    static let maximumSpeechLength = 250
    static let maximumSentences = 3

    static func speechText(from response: String) -> String? {
        guard let cleaned = OpenClawSpeechResponseFormatter.textForSpeech(response) else {
            return nil
        }
        guard cleaned.count > directSpeechLimit else { return cleaned }

        let sentences = splitSentences(cleaned)
        var selected: [String] = []
        var length = 0

        for sentence in sentences.prefix(maximumSentences) {
            let additionalLength = sentence.count + (selected.isEmpty ? 0 : 1)
            guard length + additionalLength <= maximumSpeechLength else { break }
            selected.append(sentence)
            length += additionalLength
        }

        if !selected.isEmpty {
            return selected.joined(separator: " ")
        }

        let end = cleaned.index(
            cleaned.startIndex,
            offsetBy: min(maximumSpeechLength, cleaned.count)
        )
        return String(cleaned[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            if ".?!。？！".contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                current = ""
            }
        }

        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { sentences.append(remainder) }
        return sentences
    }
}
