import Foundation

/// Exact point lookup; the caller supplies a point code, never the device location.
struct InPostPointProvider {
    private let endpoint = URL(string: "https://api-shipx-pl.easypack24.net/v1/points")!

    static func canSearch(_ reference: String, query: ParcelPOI.Query) -> Bool {
        guard reference.range(of: #"^[A-Z]{2,5}[0-9]{2,}[A-Z0-9]*$"#, options: .regularExpression) != nil else { return false }
        guard let operatorPattern = query.operatorPattern else { return true }
        return "InPost".range(of: operatorPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func search(_ reference: String) async throws -> [SearchResult] {
        guard let reference = ParcelPOI.reference(in: reference, explicitOperator: true) else { return [] }
        var request = URLRequest(url: endpoint.appendingPathComponent(reference))
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SearchError.unavailable }
        if http.statusCode == 404 { return [] }
        guard (200...299).contains(http.statusCode) else { throw SearchError.httpStatus(http.statusCode) }
        let point: Point
        do { point = try JSONDecoder().decode(Point.self, from: data) }
        catch { throw SearchError.unavailable }
        guard point.name.caseInsensitiveCompare(reference) == .orderedSame,
              point.status == "Operating", point.virtual == "0",
              (-90...90).contains(point.location.latitude),
              (-180...180).contains(point.location.longitude) else { return [] }
        let isLocker = point.partner_id == 0 && point.type.contains("parcel_locker")
        let category = isLocker ? "parcel_locker" : "parcel_pickup"
        let coordinate = Coordinate(latitude: point.location.latitude, longitude: point.location.longitude)
        let title = "\(isLocker ? "Paczkomat InPost" : "PaczkoPunkt InPost") · \(point.name)"
        let address = [point.address?.line1, point.address?.line2].compactMap { $0 }.joined(separator: ", ")
        let destination = Destination(name: title, coordinate: coordinate,
                                      address: address.isEmpty ? nil : address)
        return [SearchResult(destination: destination, street: point.address_details?.street,
                             houseNumber: point.address_details?.building_number,
                             city: point.address_details?.city, countryCode: "pl", isPOI: true,
                             providerID: point.name, placeProvider: .inPost, category: category,
                             brand: "InPost", operatorName: "InPost", parcelReferences: [point.name],
                             openingHours: point.opening_hours == "24/7" ? "24/7" : nil,
                             phone: point.phone_number, timeZoneIdentifier: "Europe/Warsaw")]
    }

    func details(for identity: PlaceIdentity) async throws -> PlaceDetails? {
        guard identity.provider == .inPost, let reference = identity.providerID,
              let result = try await search(reference).first else { return nil }
        return PlaceDetails.partial(for: result)
    }

    private struct Point: Decodable {
        let name: String
        let type: [String]
        let status: String
        let virtual: String
        let partner_id: Int
        let location: Location
        let address: Address?
        let address_details: AddressDetails?
        let opening_hours: String?
        let phone_number: String?
    }

    private struct Location: Decodable { let latitude: Double; let longitude: Double }
    private struct Address: Decodable { let line1: String?; let line2: String? }
    private struct AddressDetails: Decodable {
        let city: String?
        let street: String?
        let building_number: String?
    }
}
