#if os(iOS)
import Foundation

/// Address spelling supplied by speech recognition is normalized as one query.
/// Place names, locality, street punctuation and postcodes stay in the payload.
nonisolated enum VoiceAddressQuery {
    private struct Token {
        let text: String
        let key: String
        let range: Range<String.Index>
    }

    private static let locale = Locale(identifier: "pl_PL")
    private static let numberPattern = #"^[0-9]{1,5}[a-zA-Z]?(?:/[0-9]{1,5})?$"#
    private static let months: Set<String> = ["stycznia", "lutego", "marca", "kwietnia", "maja", "czerwca",
        "lipca", "sierpnia", "wrzesnia", "pazdziernika", "listopada", "grudnia"]
    private static let numberWords: [String: Int] = [
        "jeden": 1, "dwa": 2, "trzy": 3, "cztery": 4, "piec": 5, "szesc": 6,
        "siedem": 7, "osiem": 8, "dziewiec": 9, "dziesiec": 10, "jedenascie": 11,
        "dwanascie": 12, "trzynascie": 13, "czternascie": 14, "pietnascie": 15,
        "szesnascie": 16, "siedemnascie": 17, "osiemnascie": 18, "dziewietnascie": 19,
        "dwadziescia": 20, "trzydziesci": 30, "czterdziesci": 40, "piecdziesiat": 50,
        "szescdziesiat": 60, "siedemdziesiat": 70, "osiemdziesiat": 80, "dziewiecdziesiat": 90,
        "sto": 100, "dwiescie": 200, "trzysta": 300, "czterysta": 400, "piecset": 500,
        "szescset": 600, "siedemset": 700, "osiemset": 800, "dziewiecset": 900
    ]
    private static let spokenLetters = ["a": "A", "be": "B", "ce": "C", "de": "D", "e": "E",
        "ef": "F", "gie": "G", "ha": "H", "i": "I", "jot": "J", "ka": "K", "el": "L",
        "em": "M", "en": "N", "o": "O", "pe": "P", "er": "R", "es": "S", "te": "T",
        "u": "U", "fal": "V", "wu": "W", "iks": "X", "igrek": "Y", "zet": "Z"]

    static func normalized(_ text: String) -> String {
        let source = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let words = tokens(source)
        var replacements: [(Range<String.Index>, String)] = []
        var index = 0
        while index < words.count {
            let start = index
            var numberStart = index
            let marked = ["numer", "nr", "numerem"].contains(words[index].key)
            if marked {
                numberStart += 1
                if numberStart < words.count, ["budynku", "domu"].contains(words[numberStart].key) {
                    numberStart += 1
                }
            }
            guard let number = number(at: numberStart, in: words, source: source) else {
                index += 1
                continue
            }
            var end = number.end
            // A date belongs to the street name, e.g. 11 Listopada, not the building.
            if end < words.count, months.contains(words[end].key) {
                index = end
                continue
            }
            var value = number.value
            let suffix = letter(at: end, in: words, source: source)
            if value.last?.isNumber == true, !value.contains("/"), let suffix {
                value += suffix.value
                end = suffix.end
            }
            let hasStreetMarker = words.prefix(numberStart).contains {
                ["ul", "ulica", "ulicy", "aleja", "alei", "al", "plac", "placu"].contains($0.key)
            }
            let endsAddressComponent = end == words.count
                || source[words[end - 1].range.upperBound..<words[end].range.lowerBound].contains(",")
                || ["w", "we"].contains(words[end].key)
            // Standalone spoken number refinements are safe. In a name, a bare
            // cardinal ("Hotel Trzy") is not enough evidence to rename the place.
            let spokenAllowed = marked || suffix != nil || (hasStreetMarker && endsAddressComponent)
                || (numberStart == 0 && end == words.count)
            if !number.spoken || spokenAllowed {
                let range = words[start].range.lowerBound..<words[end - 1].range.upperBound
                replacements.append((range, value))
            }
            index = end
        }
        var result = source
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// A correction changes only the unique building token. Dates in street
    /// names and postcodes are never edited; ambiguous multi-number queries fail.
    static func replacingBuildingNumber(in query: String, with correction: String) -> String? {
        let source = normalized(query)
        let rawCorrection = correction.trimmingCharacters(in: .whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,!?;:")))
        let replacement = normalized(rawCorrection)
        let correctionWords = tokens(rawCorrection)
        let letterOnly: String?
        if correctionWords.count == 1 {
            letterOnly = singleLetter(correctionWords[0].key)
        } else if correctionWords.count == 2,
                  ["litera", "litere"].contains(correctionWords[0].key) {
            letterOnly = singleLetter(correctionWords[1].key)
        } else {
            letterOnly = nil
        }
        guard letterOnly != nil || replacement.range(of: numberPattern, options: .regularExpression) != nil else {
            return nil
        }
        let words = tokens(source)
        let candidates = words.indices.filter { index in
            let word = words[index]
            guard word.text.range(of: numberPattern, options: .regularExpression) != nil else { return false }
            if index + 1 < words.count, months.contains(words[index + 1].key) { return false }
            if index > 0, ["mieszkania", "lokal", "lokalu"].contains(words[index - 1].key) { return false }
            return true
        }
        guard candidates.count <= 1 else { return nil }
        guard let index = candidates.first else {
            guard letterOnly == nil, !source.isEmpty else { return nil }
            return source + " " + replacement
        }
        var result = source
        if let letterOnly {
            let old = words[index].text
            guard !old.contains("/") else { return nil }
            let digits = old.prefix(while: \.isNumber)
            result.replaceSubrange(words[index].range, with: String(digits) + letterOnly)
        } else {
            result.replaceSubrange(words[index].range, with: replacement)
        }
        return result
    }

    private static func number(at index: Int, in words: [Token], source: String)
        -> (value: String, end: Int, spoken: Bool)? {
        guard index < words.count else { return nil }
        if words[index].text.range(of: numberPattern, options: .regularExpression) != nil {
            return (words[index].text.uppercased(with: locale), index + 1, false)
        }
        guard let first = numberWords[words[index].key] else { return nil }
        var value = first
        var end = index + 1
        if first >= 100, end < words.count, whitespaceBetween(words[end - 1], words[end], in: source),
           let next = numberWords[words[end].key], next < 100 {
            value += next
            end += 1
        }
        let remainder = value % 100
        if remainder >= 20, remainder % 10 == 0, end < words.count,
           whitespaceBetween(words[end - 1], words[end], in: source),
           let next = numberWords[words[end].key], (1...9).contains(next) {
            value += next
            end += 1
        }
        return (String(value), end, true)
    }

    private static func letter(at index: Int, in words: [Token], source: String)
        -> (value: String, end: Int)? {
        guard index > 0, index < words.count,
              whitespaceBetween(words[index - 1], words[index], in: source) else { return nil }
        var letterIndex = index
        var explicit = false
        if words[letterIndex].key == "z", letterIndex + 1 < words.count,
           words[letterIndex + 1].key == "litera" {
            letterIndex += 1
        }
        if ["litera", "litere"].contains(words[letterIndex].key) {
            explicit = true
            letterIndex += 1
        }
        guard letterIndex < words.count, let value = singleLetter(words[letterIndex].key) else { return nil }
        if !explicit {
            // "14 w Warszawie" must not become "14W Warszawie".
            let key = words[letterIndex].key
            let followedByLocalityMarker = letterIndex + 1 < words.count
                && ["w", "we"].contains(words[letterIndex + 1].key)
            let endsComponent = letterIndex + 1 == words.count
                || source[words[letterIndex].range.upperBound..<words[letterIndex + 1].range.lowerBound].contains(",")
            let explicitCapitalA = words[letterIndex].text == "A"
            if ["w", "z", "i", "o", "a"].contains(key), !endsComponent, !followedByLocalityMarker,
               !explicitCapitalA {
                return nil
            }
        }
        return (value, letterIndex + 1)
    }

    private static func singleLetter(_ text: String) -> String? {
        if text.count == 1, text.unicodeScalars.allSatisfy({ (97...122).contains($0.value) }) {
            return text.uppercased(with: locale)
        }
        return spokenLetters[text]
    }

    private static func whitespaceBetween(_ lhs: Token, _ rhs: Token, in source: String) -> Bool {
        source[lhs.range.upperBound..<rhs.range.lowerBound].allSatisfy(\.isWhitespace)
    }

    private static func tokens(_ text: String) -> [Token] {
        guard let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:[/-][\p{L}\p{N}]+)*"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            let raw = String(text[range])
            let key = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                .replacingOccurrences(of: "ł", with: "l")
            return Token(text: raw, key: key, range: range)
        }
    }
}
#endif
