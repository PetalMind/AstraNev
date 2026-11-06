#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

@MainActor
struct VoiceContactNavigationCriticalTests {
    @Test
    func onlyCompleteNamesMatchAndTheirOrderAndPolishDiacriticsAreRespected() throws {
        let anna = contact("Anna", "Kowalska", nickname: "Ania")
        for query in ["Anna Kowalska", "Kowalska Anna", "ANIA KOWALSKA", "Prowadź do Ania Kowalska"] {
            #expect(try #require(VoiceContactQuery(query)).select(from: [anna]).matchingContacts == 1)
        }
        for query in ["Ania", "Kowalska", "An Kowalska", "Ania Kowal", "Ani Kowalskiej", "Poczta Polska"] {
            #expect(try #require(VoiceContactQuery(query)).select(from: [anna]).matchingContacts == 0)
        }
        let lukasz = contact("Łukasz", "Żółć")
        #expect(try #require(VoiceContactQuery("zolc lukasz")).select(from: [lukasz]).matchingContacts == 1)
    }

    @Test
    func exactContactUsesOnlyItsOwnAddressForGeocoding() async throws {
        let anna = contact("Ania", "Kowalska")
        let unrelated = contact("Jan", "Nowak", id: "jan")
        let matches = try #require(VoiceContactQuery("Ania Kowalska")).select(from: [anna, unrelated])
        var geocoded: [String] = []
        let resolution = try await VoiceContactResolver.resolve(matches) { address in
            geocoded.append(address.contactID)
            return [self.result(address)]
        }
        guard case .resolved(let found) = resolution else { Issue.record("Oczekiwano jednoznacznego kontaktu."); return }
        #expect(found.destination.name == "Ania Kowalska")
        #expect(geocoded == ["anna"])
    }

    @Test
    func explicitHomeAndWorkLabelsSelectTheRequestedAddress() async throws {
        var anna = contact("Ania", "Kowalska")
        anna.addresses.append(address(id: "anna", name: "Ania Kowalska", label: "Praca", index: 1))
        for (query, label) in [("Ania Kowalska dom", "Dom"), ("Ania Kowalska do pracy", "Praca")] {
            let matches = try #require(VoiceContactQuery(query)).select(from: [anna])
            #expect(matches.matchingContacts == 1)
            #expect(matches.addresses.count == 1)
            #expect(matches.addresses.first?.label == label)
            let resolution = try await VoiceContactResolver.resolve(matches) { [self.result($0)] }
            guard case .resolved(let found) = resolution else { Issue.record("Etykieta powinna wskazać jeden adres."); continue }
            #expect(found.contactAddressLabel == label)
        }
        #expect(VoiceContactQuery("Ania Kowalska dom praca") == nil)
    }

    @Test
    func duplicateContactsRemainAmbiguousEvenWhenOnlyOneHasAnAddress() async throws {
        let anna = contact("Ania", "Kowalska")
        var duplicate = contact("Ania", "Kowalska", id: "other")
        duplicate.addresses = []
        let matches = try #require(VoiceContactQuery("Ania Kowalska")).select(from: [anna, duplicate])
        let resolution = try await VoiceContactResolver.resolve(matches) { [self.result($0)] }
        guard case .ambiguous(let results, let contacts, let addresses) = resolution else {
            Issue.record("Drugi kontakt bez adresu nie może zniknąć z oceny jednoznaczności."); return
        }
        #expect(contacts == 2)
        #expect(addresses == 1)
        #expect(results.count == 1)
    }

    @Test
    func failedGeocodingNeverTurnsTwoAddressesIntoAnAutomaticChoice() async throws {
        var anna = contact("Ania", "Kowalska")
        anna.addresses.append(address(id: "anna", name: "Ania Kowalska", label: "Praca", index: 1))
        let matches = try #require(VoiceContactQuery("Ania Kowalska")).select(from: [anna])
        let resolution = try await VoiceContactResolver.resolve(matches) { address in
            if address.addressIndex == 1 { throw SearchError.unavailable }
            return [self.result(address)]
        }
        guard case .ambiguous(let results, let contacts, let addresses) = resolution else {
            Issue.record("Błąd geokodowania nie może wybrać jednego z dwóch adresów."); return
        }
        #expect(contacts == 1)
        #expect(addresses == 2)
        #expect(results.count == 1)
    }

    @Test
    func multipleMapLocationsForOneAddressAreNeverRankedByDistance() async throws {
        let matches = try #require(VoiceContactQuery("Ania Kowalska")).select(from: [contact("Ania", "Kowalska")])
        let multiple = try await VoiceContactResolver.resolve(matches) { address in
            [self.result(address), self.result(address)]
        }
        guard case .unavailable(.ambiguousAddress) = multiple else {
            Issue.record("Dwie lokalizacje wymagają uzupełnienia adresu."); return
        }
        let rawAmbiguity = try await VoiceContactResolver.resolve(matches) { _ in
            throw VoiceContactGeocodingError.ambiguousAddress
        }
        guard case .unavailable(.ambiguousAddress) = rawAmbiguity else {
            Issue.record("Nie wolno zgubić wieloznaczności surowych wyników geokodera."); return
        }
    }

    @Test
    func missingNameMissingAddressAndFailedLocationStayDistinct() async throws {
        let anna = contact("Ania", "Kowalska")
        let absent = try #require(VoiceContactQuery("Jan Nowak")).select(from: [anna])
        let absentResult = try await VoiceContactResolver.resolve(absent) { _ in
            Issue.record("Nie należy geokodować niedopasowanego kontaktu."); return []
        }
        guard case .noMatch = absentResult else { Issue.record("Oczekiwano braku dopasowania."); return }
        let noWork = try #require(VoiceContactQuery("Ania Kowalska praca")).select(from: [anna])
        let noAddress = try await VoiceContactResolver.resolve(noWork) { _ in
            Issue.record("Brakujący adres nie powinien trafić do geokodera."); return []
        }
        guard case .unavailable(.noPostalAddress) = noAddress else { Issue.record("Oczekiwano braku adresu."); return }
        let matches = try #require(VoiceContactQuery("Ania Kowalska")).select(from: [anna])
        let failed = try await VoiceContactResolver.resolve(matches) { _ in [] }
        guard case .unavailable(.geocodingFailed) = failed else { Issue.record("Oczekiwano błędu geokodowania."); return }
    }

    private func contact(_ given: String, _ family: String, id: String = "anna", nickname: String = "") -> VoiceContactRecord {
        VoiceContactRecord(givenName: given, familyName: family, nickname: nickname,
            addresses: [address(id: id, name: "\(given) \(family)", label: "Dom")])
    }

    private func address(id: String, name: String, label: String, index: Int = 0) -> VoiceContactAddress {
        VoiceContactAddress(contactID: id, addressIndex: index, name: name, label: label,
            address: "ul. Przykładowa \(index + 1), 00-001 Warszawa")
    }

    private func result(_ address: VoiceContactAddress) -> SearchResult {
        SearchResult(destination: Destination(name: address.name, coordinate: .init(latitude: 52, longitude: 21),
            address: address.address), street: nil, houseNumber: nil, city: nil, countryCode: nil,
            isContact: true, contactAddressLabel: address.label)
    }
}
#endif
