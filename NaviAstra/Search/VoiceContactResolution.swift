#if os(iOS)
import Foundation

enum VoiceContactResolution {
    case noMatch
    case resolved(SearchResult)
    case ambiguous(results: [SearchResult], matchingContacts: Int, matchingAddresses: Int)
    case unavailable(VoiceContactUnavailableReason)
}

enum VoiceContactUnavailableReason: Equatable {
    case accessNotGranted
    case noPostalAddress
    case geocodingFailed
    case ambiguousAddress

    var message: String {
        switch self {
        case .accessNotGranted:
            "Nie mam dostępu do kontaktów. Możesz zezwolić na dostęp w ustawieniach aplikacji."
        case .noPostalAddress:
            "Kontakt jest zapisany, ale nie ma adresu pasującego do polecenia. Uzupełnij adres w Kontaktach."
        case .geocodingFailed:
            "Nie udało się znaleźć adresu kontaktu na mapie. Sprawdź zapisany adres i połączenie z internetem."
        case .ambiguousAddress:
            "Adres kontaktu wskazuje kilka różnych miejsc. Uzupełnij ulicę, numer lub miejscowość w Kontaktach i spróbuj ponownie."
        }
    }
}

nonisolated enum VoiceContactGeocodingError: Error {
    case ambiguousAddress
}

nonisolated struct VoiceContactAddress: Sendable {
    var contactID: String
    var addressIndex: Int
    var name: String
    var label: String
    var address: String
}

nonisolated struct VoiceContactRecord: Sendable {
    var givenName: String
    var middleName: String = ""
    var familyName: String
    var nickname: String = ""
    var addresses: [VoiceContactAddress]
}

nonisolated struct VoiceContactMatches: Sendable {
    var matchingContacts: Int
    var addresses: [VoiceContactAddress]
}

/// A voice command may act immediately only on a complete, exact name.
/// Search-sheet prefix/stem matching deliberately remains separate.
nonisolated struct VoiceContactQuery: Sendable {
    private var nameTokens: [String]
    private var addressLabel: String?

    init?(_ query: String) {
        var value = Self.normalize(query)
        for prefix in ["prowadz do ", "nawiguj do ", "jedz do ", "do "] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        var tokens = Self.tokens(value)
        let home: Set<String> = ["dom", "domu", "mieszkanie"]
        let work: Set<String> = ["praca", "pracy", "biuro"]
        let requestedHome = tokens.contains(where: home.contains)
        let requestedWork = tokens.contains(where: work.contains)
        guard !(requestedHome && requestedWork) else { return nil }
        if requestedHome || requestedWork,
           let index = tokens.firstIndex(where: { home.contains($0) || work.contains($0) }),
           index > 0, tokens[index - 1] == "do" {
            tokens.remove(at: index - 1)
        }
        if requestedHome {
            addressLabel = "dom"
            tokens.removeAll(where: home.contains)
        } else if requestedWork {
            addressLabel = "praca"
            tokens.removeAll(where: work.contains)
        }
        guard !tokens.isEmpty else { return nil }
        nameTokens = tokens.sorted()
    }

    func matches(_ contact: VoiceContactRecord) -> Bool {
        let given = Self.tokens(contact.givenName)
        let family = Self.tokens(contact.familyName)
        let middle = Self.tokens(contact.middleName)
        let nickname = Self.tokens(contact.nickname)
        var variants = [given + family, given + middle + family]
        if !nickname.isEmpty {
            variants.append(nickname + family)
            variants.append(nickname + middle + family)
        }
        return variants.contains { !$0.isEmpty && $0.sorted() == nameTokens }
    }

    func matchesLabel(_ label: String) -> Bool {
        guard let addressLabel else { return true }
        return Self.normalize(label) == addressLabel
    }

    func select(from contacts: [VoiceContactRecord]) -> VoiceContactMatches {
        let matched = contacts.filter(matches)
        return VoiceContactMatches(matchingContacts: matched.count,
            addresses: matched.flatMap(\.addresses).filter { matchesLabel($0.label) })
    }

    private static func tokens(_ value: String) -> [String] {
        normalize(value).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .replacingOccurrences(of: "ł", with: "l")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
enum VoiceContactResolver {
    static func resolve(_ matches: VoiceContactMatches,
                        geocode: (VoiceContactAddress) async throws -> [SearchResult]) async throws -> VoiceContactResolution {
        guard matches.matchingContacts > 0 else { return .noMatch }
        let needsChoice = matches.matchingContacts > 1 || matches.addresses.count > 1
        guard !matches.addresses.isEmpty else {
            if needsChoice {
                return .ambiguous(results: [], matchingContacts: matches.matchingContacts, matchingAddresses: 0)
            }
            return .unavailable(.noPostalAddress)
        }

        var results: [SearchResult] = []
        for address in matches.addresses.prefix(6) {
            try Task.checkCancellation()
            do {
                let located = try await geocode(address)
                try Task.checkCancellation()
                // Several map locations for one postal address must never be ranked by proximity.
                guard located.count <= 1 else { return .unavailable(.ambiguousAddress) }
                results.append(contentsOf: located)
            } catch is CancellationError {
                throw CancellationError()
            } catch VoiceContactGeocodingError.ambiguousAddress {
                return .unavailable(.ambiguousAddress)
            } catch {
                // A failed address does not remove its original ambiguity.
            }
        }
        try Task.checkCancellation()
        if needsChoice {
            return .ambiguous(results: results, matchingContacts: matches.matchingContacts,
                              matchingAddresses: matches.addresses.count)
        }
        guard let result = results.first else { return .unavailable(.geocodingFailed) }
        return .resolved(result)
    }
}
#endif
