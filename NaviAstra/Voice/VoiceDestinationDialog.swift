#if os(iOS)
import Foundation

/// A short-lived address draft, separate from an executable route confirmation.
/// Keeping the base and the supplied locality separate avoids accumulating old towns.
struct VoiceDestinationDialog {
    enum Awaiting { case selection, locality, correction }
    var baseQuery: String
    var locality: String?
    private var localityComesFirst = false
    var awaiting: Awaiting = .selection
    var context: VoiceDialogContext

    init(baseQuery: String, context: VoiceDialogContext) {
        self.baseQuery = baseQuery
        self.context = context
        let parts = baseQuery.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let first = parts.first, let last = parts.last {
            if first.contains(where: \.isNumber), Self.isLocality(last) {
                self.baseQuery = first
                locality = last
            } else if last.contains(where: \.isNumber), Self.isLocality(first) {
                self.baseQuery = last
                locality = first
                localityComesFirst = true
            }
        }
    }

    var query: String {
        let parts = localityComesFirst ? [locality, baseQuery] : [baseQuery, locality]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    mutating func refine(_ text: String, explicitCorrection: Bool) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".!?„”\"")))
        guard !raw.isEmpty else { return false }
        if let corrected = VoiceAddressQuery.replacingBuildingNumber(in: baseQuery, with: raw) {
            baseQuery = corrected
            return true
        }
        let folded = QueryClassifier.normalize(raw)
        let locationPrefixes = ["miejscowosc to ", "miejscowosc ", "w miejscowosci ", "miasto to ", "miasto ", "gmina ", "w gminie "]
        if let prefix = locationPrefixes.first(where: folded.hasPrefix) {
            let count = prefix.split(separator: " ").count
            let value = raw.split(separator: " ").dropFirst(count).joined(separator: " ")
            guard Self.isLocality(value) else { return false }
            locality = value
            return true
        }
        // A full address correction replaces the draft; a bare place name
        // answers the current locality/correction question.
        if !explicitCorrection, Self.isLocality(raw) {
            locality = raw
            return true
        }
        if explicitCorrection {
            let normalized = VoiceAddressQuery.normalized(raw)
            guard normalized.range(of: #"^(?:[0-9]+[A-Za-z]?(?:/[0-9]+)?|[A-Za-z]|litera [A-Za-z])$"#,
                                   options: .regularExpression) == nil else { return false }
            // Do not turn a quoted or negated command into a new destination.
            guard Self.isAddressReply(raw) else { return false }
            self = Self(baseQuery: VoiceAddressQuery.normalized(raw), context: context)
            return true
        }
        return false
    }

    private static func isAddressReply(_ value: String) -> Bool {
        let words = QueryClassifier.normalize(value).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let controlWords: Set<String> = ["nie", "tak", "anuluj", "powtorz", "polecenie", "komunikat", "glosnik",
            "powiedziala", "powiedzial", "powiedz", "aplikacja", "nawiguj", "prowadz", "wybierz", "pomoc", "stop"]
        return !words.isEmpty && words.count <= 24 && !words.contains(where: controlWords.contains)
    }

    private static func isLocality(_ value: String) -> Bool {
        isAddressReply(value) && value.contains(where: \.isLetter)
            && !value.contains(where: \.isNumber) && value.split(separator: " ").count <= 8
    }
}
#endif
