#if os(iOS)
import Foundation
import MapKit

/// Nearby categories must not require their generic label to occur in a name:
/// a fuel search includes ORLEN and Shell, not only places called "Stacja paliw".
struct MapKitCategorySearchProvider {
    static func supports(_ intent: ClassifiedQuery) -> Bool {
        intent.intent == .category && !intent.alongRoute && intent.parcelQuery == nil
            && category(for: intent) != nil
    }

    func search(_ intent: ClassifiedQuery, near center: Coordinate) async throws -> [SearchResult] {
        guard Self.supports(intent), let category = Self.category(for: intent),
              let localRadius = SearchGeographicScope.radii(for: intent).first else { return [] }
        // Apple caps nearby POI requests. The other providers retain the wider
        // rings; do not pretend this source covered an unsupported radius.
        let radius = min(localRadius, MKLocalPointsOfInterestRequest.maxRadius)
        let request = MKLocalPointsOfInterestRequest(center: center.cl, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [category])
        let search = MKLocalSearch(request: request)
        return try await fetch(search, category: category, center: center, radius: radius)
    }

    /// Covers the rest of the local ring beyond Apple's nearby-POI radius cap.
    /// The category filter supplies the meaning; the user's generic Polish
    /// phrase must not require that phrase to occur in the station's name.
    func searchTextFallback(_ intent: ClassifiedQuery, near center: Coordinate) async throws -> [SearchResult] {
        guard Self.supports(intent), intent.photonTag == "amenity:fuel",
              let radius = SearchGeographicScope.radii(for: intent).first else { return [] }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "gas station"
        request.resultTypes = [.pointOfInterest]
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation])
        request.region = MKCoordinateRegion(center: center.cl,
            latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        request.regionPriority = .required
        return try await fetch(MKLocalSearch(request: request), category: .gasStation,
                               center: center, radius: radius)
    }

    private func fetch(_ search: MKLocalSearch, category: MKPointOfInterestCategory,
                       center: Coordinate, radius: Double) async throws -> [SearchResult] {
        let response = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await search.start()
        } onCancel: {
            Task { @MainActor in search.cancel() }
        }
        try Task.checkCancellation()
        return response.mapItems.compactMap { item in
            let location = item.location.coordinate
            let coordinate = Coordinate(latitude: location.latitude, longitude: location.longitude)
            guard (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude),
                  center.distance(to: coordinate) <= radius,
                  // A nil category can also describe a plain address. The
                  // request filter alone must not turn it into a fuel station.
                  item.pointOfInterestCategory == category,
                  let rawName = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else { return nil }
            let representations = item.addressRepresentations
            let city = representations?.cityName
            // Apple can label a verified station with only its city name.
            // Keep the provider identity/address, but show its known place type.
            let nameMatchesCity = city.map {
                SearchRanking.normalizedIdentity(rawName) == SearchRanking.normalizedIdentity($0)
            } ?? false
            let name = category == .gasStation && nameMatchesCity ? "Stacja paliw" : rawName
            return SearchResult(destination: Destination(name: name, coordinate: coordinate,
                address: item.address?.fullAddress), street: nil, houseNumber: nil,
                city: city,
                countryCode: representations?.region?.identifier.lowercased(),
                isPOI: true, providerID: item.identifier?.rawValue, placeProvider: .mapKit,
                category: category.rawValue, phone: item.phoneNumber,
                website: item.url?.absoluteString, timeZoneIdentifier: item.timeZone?.identifier)
        }
    }

    private static func category(for intent: ClassifiedQuery) -> MKPointOfInterestCategory? {
        switch intent.photonTag {
        case "amenity:fuel": .gasStation
        case "amenity:pharmacy": .pharmacy
        case "amenity:parking": .parking
        case "amenity:charging_station": .evCharger
        case "shop:supermarket": .foodMarket
        case "amenity:restaurant": .restaurant
        case "amenity:cafe": .cafe
        case "tourism:hotel": .hotel
        case "amenity:hospital": .hospital
        case "amenity:atm": .atm
        case "amenity:toilets": .restroom
        case "amenity:post_office": .postOffice
        default: nil
        }
    }
}

struct PhotonCategorySearchProvider {
    var endpoint: URL

    static func supports(_ intent: ClassifiedQuery, endpoint: URL) -> Bool {
        guard intent.intent == .category, !intent.alongRoute, intent.parcelQuery == nil,
              let tag = intent.photonTag, endpoint.lastPathComponent == "api" else { return false }
        // Photon filters principal OSM tags. Secondary cuisine tags still need
        // the existing text search, and custom API paths are left untouched.
        return ["amenity", "shop", "tourism"].contains(String(tag.prefix { $0 != ":" }))
    }

    func search(_ intent: ClassifiedQuery, near center: Coordinate) async throws -> [SearchResult] {
        guard Self.supports(intent, endpoint: endpoint), let tag = intent.photonTag,
              let radius = SearchGeographicScope.radii(for: intent).last else { return [] }
        var components = URLComponents(url: endpoint.deletingLastPathComponent().appendingPathComponent("reverse"),
                                       resolvingAgainstBaseURL: false)!
        // Photon documents /reverse + osm_tag for nearby categories. There is
        // deliberately no q: a brand name must not match the generic query text.
        components.queryItems = [URLQueryItem(name: "lat", value: String(center.latitude)),
            URLQueryItem(name: "lon", value: String(center.longitude)),
            URLQueryItem(name: "radius", value: String(radius / 1_000)),
            URLQueryItem(name: "osm_tag", value: tag), URLQueryItem(name: "limit", value: "40"),
            URLQueryItem(name: "dedupe", value: "0"), URLQueryItem(name: "lang", value: "default")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SearchError.unavailable }
        guard (200...299).contains(http.statusCode) else { throw SearchError.httpStatus(http.statusCode) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let requestedTag = tag.split(separator: ":", maxSplits: 1).map(String.init)
        return reply.features.compactMap { feature in
            let p = feature.properties
            guard feature.geometry.coordinates.count >= 2, requestedTag.count == 2,
                  p.osm_key == requestedTag[0], p.osm_value == requestedTag[1] else { return nil }
            let coordinate = Coordinate(latitude: feature.geometry.coordinates[1], longitude: feature.geometry.coordinates[0])
            guard (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude),
                  center.distance(to: coordinate) <= radius else { return nil }
            let streetLine = [p.street, p.housenumber].compactMap { $0 }.joined(separator: " ")
            let locality = [p.postcode, p.city ?? p.locality].compactMap { $0 }.joined(separator: " ")
            let address = [streetLine, locality].filter { !$0.isEmpty }.joined(separator: ", ")
            let name = p.name.flatMap { $0.isEmpty ? nil : $0 } ?? intent.text.capitalized
            return SearchResult(destination: Destination(name: name, coordinate: coordinate,
                address: address.isEmpty ? nil : address), street: p.street, houseNumber: p.housenumber,
                city: p.city ?? p.locality, countryCode: p.countrycode, isPOI: true,
                osmID: p.osm_id.map { "\(p.osm_type ?? ""):\($0)" }, category: p.osm_value)
        }
    }

    private struct Reply: Decodable { var features: [Feature] }
    private struct Feature: Decodable { var geometry: Geometry; var properties: Properties }
    private struct Geometry: Decodable { var coordinates: [Double] }
    private struct Properties: Decodable {
        var name: String?; var street: String?; var housenumber: String?; var postcode: String?
        var city: String?; var locality: String?; var countrycode: String?
        var osm_id: Int64?; var osm_type: String?; var osm_key: String?; var osm_value: String?
    }
}
#endif
