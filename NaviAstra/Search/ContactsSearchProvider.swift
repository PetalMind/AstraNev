import Contacts
import Foundation
import MapKit

enum ContactsAccessStatus: Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized

    var canReadContacts: Bool { self == .authorized }

    static func current() -> ContactsAccessStatus {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .notDetermined:
            .notDetermined
        @unknown default:
            .restricted
        }
    }
}

struct ContactsSearchProvider: SearchProvider {
    nonisolated private struct ContactAddress: Sendable {
        var contactID: String
        var addressIndex: Int
        var name: String
        var label: String
        var address: String
    }

    func requestAccess() async -> ContactsAccessStatus {
        guard ContactsAccessStatus.current() == .notDetermined else {
            return ContactsAccessStatus.current()
        }
        do {
            _ = try await CNContactStore().requestAccess(for: .contacts)
        } catch {
            return ContactsAccessStatus.current()
        }
        return ContactsAccessStatus.current()
    }

    func search(_ query: String, near: Coordinate?) async throws -> [SearchResult] {
        guard ContactsAccessStatus.current().canReadContacts else { throw SearchError.unavailable }
        guard let terms = Self.searchTerms(query), !terms.nameTokens.isEmpty else {
            throw SearchError.unavailable
        }

        let addresses = try await Task.detached(priority: .userInitiated) {
            try Self.fetchAddresses(matching: terms)
        }.value
        try Task.checkCancellation()

        let results = try await withThrowingTaskGroup(of: SearchResult?.self) { group in
            for address in addresses.prefix(6) {
                group.addTask { @MainActor in
                    do {
                        return try await geocodedResult(for: address, near: near)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return nil
                    }
                }
            }
            var results: [SearchResult] = []
            for try await result in group {
                try Task.checkCancellation()
                if let result { results.append(result) }
            }
            return results.sorted {
                let left = QueryClassifier.normalize($0.destination.name)
                let right = QueryClassifier.normalize($1.destination.name)
                if left != right { return left < right }
                return ($0.contactAddressLabel ?? "") < ($1.contactAddressLabel ?? "")
            }
        }
        guard !results.isEmpty else { throw SearchError.unavailable }
        return results
    }

    nonisolated private struct SearchTerms: Sendable {
        var nameTokens: [String]
        var addressTokens: [String]
        var addressLabel: String?
    }

    private static func searchTerms(_ query: String) -> SearchTerms? {
        var value = normalized(query)
        for prefix in ["jedz do ", "prowadz do ", "nawiguj do ", "do "] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        if value.hasSuffix(" po trasie") { value.removeLast(" po trasie".count) }

        var tokens = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        let homeLabels: Set<String> = ["dom", "domu", "home", "mieszkanie"]
        let workLabels: Set<String> = ["praca", "pracy", "pracę", "prace", "work", "biuro"]
        let requestedLabel: String?
        if tokens.contains(where: homeLabels.contains) {
            requestedLabel = "dom"
            tokens.removeAll(where: homeLabels.contains)
        } else if tokens.contains(where: workLabels.contains) {
            requestedLabel = "praca"
            tokens.removeAll(where: workLabels.contains)
        } else {
            requestedLabel = nil
        }

        let addressTokens = tokens
        return SearchTerms(nameTokens: tokens, addressTokens: addressTokens,
                           addressLabel: requestedLabel)
    }

    nonisolated private static func fetchAddresses(matching terms: SearchTerms) throws -> [ContactAddress] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault

        var addresses: [ContactAddress] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let nameParts = [contact.givenName, contact.middleName, contact.familyName,
                             contact.nickname, contact.organizationName]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !nameParts.isEmpty else { return }
            let name = [contact.givenName, contact.middleName, contact.familyName]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: " ")
            let displayName = name.isEmpty ? (contact.nickname.isEmpty ? contact.organizationName : contact.nickname) : name
            let searchableName = normalized(([displayName, contact.nickname, contact.organizationName] + nameParts).joined(separator: " "))
            let nameWords = searchableName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let nameMatches = terms.nameTokens.allSatisfy { queryToken in
                nameWords.contains { Self.matches(queryToken, $0) }
            }
            let addressMatches = terms.addressLabel == nil && !terms.addressTokens.isEmpty

            for (index, labeledAddress) in contact.postalAddresses.enumerated() {
                let postalAddress = labeledAddress.value
                let formatted = CNPostalAddressFormatter.string(from: postalAddress, style: .mailingAddress)
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                guard !formatted.isEmpty else { continue }

                let label = Self.polishLabel(labeledAddress.label)
                if let requestedLabel = terms.addressLabel,
                   normalized(label) != requestedLabel { continue }

                let addressWords = normalized(formatted)
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                let addressMatchesQuery = addressMatches && terms.addressTokens.allSatisfy { queryToken in
                    addressWords.contains { Self.matches(queryToken, $0) }
                }
                guard nameMatches || addressMatchesQuery else { continue }

                addresses.append(ContactAddress(contactID: contact.identifier,
                                                 addressIndex: index,
                                                 name: displayName,
                                                 label: label,
                                                 address: formatted))
            }
        }
        return addresses
    }

    @MainActor
    private func geocodedResult(for contactAddress: ContactAddress,
                                near coordinate: Coordinate?) async throws -> SearchResult? {
        guard let request = MKGeocodingRequest(addressString: contactAddress.address) else { return nil }
        request.preferredLocale = Locale(identifier: "pl_PL")
        if let coordinate {
            request.region = MKCoordinateRegion(center: coordinate.cl,
                                                latitudinalMeters: 100_000,
                                                longitudinalMeters: 100_000)
        }

        let mapItems: [MKMapItem] = try await withTaskCancellationHandler(
            operation: { try await requestMapItems(for: request) },
            onCancel: { Task { @MainActor in request.cancel() } })
        try Task.checkCancellation()

        let item = mapItems.min { lhs, rhs in
            guard let coordinate else { return false }
            let left = Coordinate(latitude: lhs.location.coordinate.latitude,
                                  longitude: lhs.location.coordinate.longitude)
            let right = Coordinate(latitude: rhs.location.coordinate.latitude,
                                   longitude: rhs.location.coordinate.longitude)
            return coordinate.distance(to: left) < coordinate.distance(to: right)
        } ?? mapItems.first
        guard let item else { return nil }
        let location = item.location.coordinate
        let resultCoordinate = Coordinate(latitude: location.latitude, longitude: location.longitude)
        guard (-90...90).contains(resultCoordinate.latitude), (-180...180).contains(resultCoordinate.longitude) else { return nil }

        let destination = Destination(name: contactAddress.name,
                                      coordinate: resultCoordinate,
                                      address: contactAddress.address)
        return SearchResult(destination: destination,
                            street: nil,
                            houseNumber: nil,
                            city: nil,
                            countryCode: nil,
                            providerID: "contact-\(contactAddress.contactID)-\(contactAddress.addressIndex)",
                            placeProvider: .mapKit,
                            isContact: true,
                            contactAddressLabel: contactAddress.label)
    }

    private func requestMapItems(for request: MKGeocodingRequest) async throws -> [MKMapItem] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[MKMapItem], Error>) in
            request.getMapItems { items, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: items ?? [])
                }
            }
        }
    }

    nonisolated private static func polishLabel(_ label: String?) -> String {
        guard let label else { return "Adres" }
        if label == CNLabelHome { return "Dom" }
        if label == CNLabelWork { return "Praca" }
        if label == CNLabelOther { return "Inny adres" }
        let localized = CNLabeledValue<CNPostalAddress>.localizedString(forLabel: label)
        return localized.isEmpty ? "Adres" : localized
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func matches(_ queryToken: String, _ contactToken: String) -> Bool {
        let queryStem = stem(queryToken)
        let contactStem = stem(contactToken)
        return queryStem == contactStem || queryStem.hasPrefix(contactStem) || contactStem.hasPrefix(queryStem)
    }

    nonisolated private static func stem(_ token: String) -> String {
        for suffix in ["owie", "ami", "ach", "ego", "emu", "ia", "y", "a", "i", "u", "ę", "ą", "e"]
            where token.count - suffix.count >= 3 && token.hasSuffix(suffix) {
            return String(token.dropLast(suffix.count))
        }
        return token
    }
}
