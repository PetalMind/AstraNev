import Foundation
import CoreFoundation

nonisolated enum StationFuel: String, CaseIterable, Identifiable, Sendable {
    case pb95, pb98, diesel = "on", premiumDiesel = "on_plus", lpg

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pb95: "PB 95"
        case .pb98: "PB 98"
        case .diesel: "ON"
        case .premiumDiesel: "ON+"
        case .lpg: "LPG"
        }
    }
}

nonisolated struct StationFuelPrice: Identifiable, Sendable {
    let fuel: StationFuel
    let amount: Decimal
    let reportedAt: Date?
    var id: String { fuel.rawValue }
    var isRecent: Bool {
        guard let reportedAt else { return false }
        let age = Date().timeIntervalSince(reportedAt)
        return age >= 0 && age < 5 * 24 * 60 * 60
    }
}

nonisolated struct StationFuelPrices: Sendable {
    let stationID: String
    let prices: [StationFuelPrice]
    let isClosed: Bool
    var sourceURL: URL { URL(string: "https://paliwomapa.pl/?stacja=\(stationID)")! }
}

/// Read-only adapter for the public data used by paliwomapa.pl (see docs/FUEL_PRICES.md).
@MainActor
final class PaliwoMapaFuelPriceProvider {
    static let shared = PaliwoMapaFuelPriceProvider()
    private var stations: [FuelStation] = []
    private var stationsLoadedAt: Date?
    private var stationRequest: Task<[FuelStation], Error>?
    private var cache: [String: (value: StationFuelPrices, fetchedAt: Date)] = [:]
    private var requests: [String: Task<StationFuelPrices, Error>] = [:]

    static func isFuelStation(category: String?) -> Bool {
        guard let category else { return false }
        let value = normalized(category.split(separator: "=").last.map(String.init) ?? category)
            .replacingOccurrences(of: "mkpoicategory", with: "")
        return ["fuel", "gasstation", "petrolstation", "stacjapaliw"].contains(value)
    }

    func prices(for identity: PlaceIdentity, forceRefresh: Bool = false) async throws -> StationFuelPrices? {
        // PaliwoMapa's catalogue covers Poland only.
        if let country = identity.countryCode, country.lowercased() != "pl" { return nil }
        guard (48.9...55.0).contains(identity.coordinate.latitude),
              (14.0...24.3).contains(identity.coordinate.longitude) else { return nil }
        let catalog = try await loadStations()
        try Task.checkCancellation()
        guard let station = match(identity, in: catalog) else { return nil }
        let key = String(station.id)
        if !forceRefresh, let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < 15 * 60 {
            return cached.value
        }
        if let request = requests[key] { return try await request.value }
        let request = Task { try await Self.fetchPrices(stationID: key) }
        requests[key] = request
        defer { requests[key] = nil }
        let value = try await request.value
        if cache.count >= 100 { cache.removeAll() }
        cache[key] = (value, Date())
        return value
    }

    private func loadStations() async throws -> [FuelStation] {
        if let stationsLoadedAt, Date().timeIntervalSince(stationsLoadedAt) < 24 * 60 * 60 {
            return stations
        }
        if let stationRequest { return try await stationRequest.value }
        let request = Task {
            let data = try await Self.download(URLRequest(url: URL(string: "https://paliwomapa.pl/stacje.json")!))
            return try await Task.detached(priority: .utility) {
                let decoder = JSONDecoder()
                if let array = try? decoder.decode([FuelStation].self, from: data) { return array }
                return try decoder.decode(StationCatalogue.self, from: data).elements
            }.value
        }
        stationRequest = request
        defer { stationRequest = nil }
        stations = try await request.value
        guard !stations.isEmpty else { throw URLError(.cannotParseResponse) }
        stationsLoadedAt = Date()
        return stations
    }

    private func match(_ identity: PlaceIdentity, in catalog: [FuelStation]) -> FuelStation? {
        let nearby = catalog.filter {
            guard let coordinate = $0.coordinate else { return false }
            return coordinate.distance(to: identity.coordinate) <= 250
        }
        if identity.provider != .mapKit, let id = identity.externalID, let numericID = Int64(id) {
            let exact = nearby.filter {
                $0.id == numericID && (identity.osmType == nil || $0.type == identity.osmType)
            }
            if exact.count == 1 {
                // Prices use bare numeric IDs. Refuse an OSM node/way ID collision.
                guard catalog.filter({ $0.id == numericID }).count == 1 else { return nil }
                return exact[0]
            }
        }
        // Apple Maps and unmatched vector POIs: require both proximity and a meaningful
        // identical name/brand. Never assign the nearest station's prices blindly.
        let names = Set([identity.brand, identity.name, identity.operatorName].compactMap { $0 }
            .map(Self.normalized).filter(Self.isMeaningfulName))
        let candidates = nearby.filter { station in
            guard let coordinate = station.coordinate,
                  coordinate.distance(to: identity.coordinate) <= 80 else { return false }
            let stationNames = Set([station.tags["brand"], station.tags["name"], station.tags["operator"]]
                .compactMap { $0 }.map(Self.normalized).filter(Self.isMeaningfulName))
            return !names.isDisjoint(with: stationNames)
        }
        guard candidates.count == 1,
              catalog.filter({ $0.id == candidates[0].id }).count == 1 else { return nil }
        return candidates[0]
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func isMeaningfulName(_ value: String) -> Bool {
        !value.isEmpty && !["fuel", "gasstation", "petrolstation", "stacjapaliw", "stacja", "paliwo", "paliw"]
            .contains(value)
    }

    private static func fetchPrices(stationID: String) async throws -> StationFuelPrices {
        var url = URLComponents(string: "https://hcxxwweqkkjspytgyool.supabase.co/rest/v1/app_docs")!
        url.queryItems = [
            URLQueryItem(name: "select", value: "doc_id,data"),
            URLQueryItem(name: "collection_name", value: "eq.prices"),
            URLQueryItem(name: "parent_path", value: "is.null"),
            URLQueryItem(name: "doc_id", value: "eq.\(stationID)"),
            URLQueryItem(name: "limit", value: "1")
        ]
        var request = URLRequest(url: url.url!)
        // Publishable browser key from window.PM_SUPABASE_CONFIG, not an admin credential.
        request.setValue("sb_publishable_HeTnHlo6wWxGZKk02pYO8w_UsYG0PuP", forHTTPHeaderField: "apikey")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data = try await download(request)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        guard let row = rows.first else {
            return StationFuelPrices(stationID: stationID, prices: [], isClosed: false)
        }
        guard row["doc_id"] as? String == stationID, let payload = row["data"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let prices = StationFuel.allCases.compactMap { fuel -> StationFuelPrice? in
            let raw = payload[fuel.rawValue]
            if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            guard let text = (raw as? NSNumber)?.stringValue ?? (raw as? String),
                  let amount = Decimal(string: text.replacingOccurrences(of: ",", with: "."),
                                       locale: Locale(identifier: "en_US_POSIX")),
                  amount > 0, amount < 100 else { return nil }
            // A station-wide update must not make an older, unchanged fuel look fresh.
            let timestamp = payload["ud_" + fuel.rawValue] ?? payload["updated"]
            return StationFuelPrice(fuel: fuel, amount: amount, reportedAt: reportedDate(timestamp))
        }
        return StationFuelPrices(stationID: stationID, prices: prices, isClosed: payload["closed"] as? Bool == true)
    }

    private static func reportedDate(_ raw: Any?) -> Date? {
        if let text = raw as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        if let object = raw as? [String: Any], let seconds = object["seconds"] as? Double {
            return Date(timeIntervalSince1970: seconds)
        }
        if let milliseconds = raw as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        return nil
    }

    private static func download(_ input: URLRequest) async throws -> Data {
        var request = input
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

nonisolated private struct StationCatalogue: Decodable { let elements: [FuelStation] }

nonisolated private struct FuelStation: Decodable, Sendable {
    let type: String
    let id: Int64
    let lat: Double?
    let lon: Double?
    let center: Center?
    let tags: [String: String]

    var coordinate: Coordinate? {
        guard let latitude = lat ?? center?.lat, let longitude = lon ?? center?.lon,
              latitude.isFinite, longitude.isFinite else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    nonisolated struct Center: Decodable, Sendable { let lat: Double; let lon: Double }
}
