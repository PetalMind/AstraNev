import Foundation

struct FuelStationLookup: Sendable {
    let osmType: String?
    let osmID: String?
    let name: String
    let brand: String?
    let coordinate: Coordinate
    let countryCode: String?

    init(identity: PlaceIdentity) {
        osmType = identity.osmType
        osmID = identity.provider == .openStreetMap ? identity.externalID : nil
        name = identity.name
        brand = identity.brand ?? identity.operatorName
        coordinate = identity.coordinate
        countryCode = identity.countryCode
    }
}

struct FuelPrice: Identifiable, Sendable {
    let id: String
    let title: String
    let amount: Double
    let isEstimated: Bool
}

struct FuelPriceReport: Sendable {
    let prices: [FuelPrice]
    let source: String?
    let reportedAt: String?
}

enum FuelPriceLookupResult: Sendable {
    case outsideCoverage
    case stationNotFound
    case noPrices
    case prices(FuelPriceReport)
}

protocol FuelPriceProvider: Sendable {
    func prices(for station: FuelStationLookup) async throws -> FuelPriceLookupResult
}

actor BenzynaMapaFuelPriceProvider: FuelPriceProvider {
    static let shared = BenzynaMapaFuelPriceProvider()

    private var cachedSnapshot: Snapshot?
    private var cacheExpiresAt = Date.distantPast
    private var pendingSnapshot: Task<Snapshot, Error>?

    func prices(for station: FuelStationLookup) async throws -> FuelPriceLookupResult {
        guard isWithinPoland(station.coordinate, countryCode: station.countryCode) else {
            return .outsideCoverage
        }

        let snapshot = try await loadSnapshot()
        guard let matchedStation = match(station, in: snapshot.stations) else {
            return .stationNotFound
        }
        let key = matchedStation.id.lowercased()
        guard let report = snapshot.prices[key] else { return .noPrices }
        return .prices(report)
    }

    private func loadSnapshot() async throws -> Snapshot {
        if let cachedSnapshot, cacheExpiresAt > Date() { return cachedSnapshot }

        let task: Task<Snapshot, Error>
        if let pendingSnapshot {
            task = pendingSnapshot
        } else {
            task = Task { try await Self.fetchSnapshot() }
            pendingSnapshot = task
        }

        do {
            let snapshot = try await task.value
            cachedSnapshot = snapshot
            cacheExpiresAt = Date().addingTimeInterval(60 * 60)
            pendingSnapshot = nil
            return snapshot
        } catch {
            pendingSnapshot = nil
            throw error
        }
    }

    nonisolated private static func fetchSnapshot() async throws -> Snapshot {
        let pricesURL = URL(string: "https://benzynamapa.pl/data/prices_latest.json")!
        let stationsURL = URL(string: "https://benzynamapa.pl/data/stations_latest.json")!
        async let pricesData = download(pricesURL)
        async let stationsData = download(stationsURL)
        let (prices, stations) = try await (pricesData, stationsData)
        return try Snapshot(pricesData: prices, stationsData: stations)
    }

    nonisolated private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .useProtocolCachePolicy
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NaviAstra/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw FuelPriceProviderError.unavailable
        }
        return data
    }

    private func isWithinPoland(_ coordinate: Coordinate, countryCode: String?) -> Bool {
        if let countryCode {
            let normalizedCountry = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalizedCountry.isEmpty && normalizedCountry != "pl" { return false }
        }
        return (49.0...55.2).contains(coordinate.latitude) && (14.0...24.2).contains(coordinate.longitude)
    }

    private func match(_ lookup: FuelStationLookup, in stations: [Station]) -> Station? {
        let osmID = lookup.osmID.flatMap { Int64($0) }
        if let osmID {
            let exactMatches = stations.filter { station in
                station.osmID == osmID &&
                    (station.osmType == nil || lookup.osmType == nil || station.osmType == lookup.osmType)
            }
            if let closest = exactMatches.min(by: {
                distance(from: lookup.coordinate, to: $0.coordinate) < distance(from: lookup.coordinate, to: $1.coordinate)
            }), distance(from: lookup.coordinate, to: closest.coordinate) <= 250 {
                return closest
            }
        }

        let candidates = stations.compactMap { station -> (station: Station, score: Int, distance: Double)? in
            let distance = distance(from: lookup.coordinate, to: station.coordinate)
            guard let nameScore = identityMatchScore(lookup, station),
                  distance <= (nameScore == 2 ? 40 : 25) else { return nil }
            return (station, nameScore, distance)
        }
        return candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.distance < $1.distance
        }.first?.station
    }

    /// Name matches are only a fallback when an OSM id is unavailable in the feed.
    private func identityMatchScore(_ lookup: FuelStationLookup, _ station: Station) -> Int? {
        let expectedNames = [lookup.name, lookup.brand].compactMap { normalized($0) }
        let actualNames = [station.name, station.brand].compactMap { normalized($0) }
        guard !expectedNames.isEmpty, !actualNames.isEmpty else { return nil }

        for expected in expectedNames {
            for actual in actualNames where expected == actual {
                return 2
            }
        }

        for expected in expectedNames {
            for actual in actualNames {
                let shorter = min(expected.count, actual.count)
                if shorter >= 6 && (expected.contains(actual) || actual.contains(expected)) {
                    return 1
                }
            }
        }
        return nil
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                   locale: Locale(identifier: "pl_PL"))
            .filter { $0.isLetter || $0.isNumber }
        return result.isEmpty ? nil : result
    }

    private func distance(from coordinate: Coordinate, to other: Coordinate) -> Double {
        return coordinate.distance(to: other)
    }

    nonisolated private struct Snapshot: Sendable {
        let stations: [Station]
        let prices: [String: FuelPriceReport]

        init(pricesData: Data, stationsData: Data) throws {
            let pricesRoot = try Self.rootObject(from: pricesData)
            let stationsRoot = try Self.rootObject(from: stationsData)
            let generatedAt = Self.string(pricesRoot["last_updated"] ?? pricesRoot["updated_at"])

            let priceRows = Self.records(in: pricesRoot, key: "prices")
            let stationRows = Self.records(in: stationsRoot, key: "stations")
            guard !priceRows.isEmpty, !stationRows.isEmpty else { throw FuelPriceProviderError.invalidResponse }

            var parsedPrices: [String: FuelPriceReport] = [:]
            for row in priceRows {
                guard let stationID = Self.string(row["station_id"] ?? row["id"]), !stationID.isEmpty else { continue }
                let estimatedAtRecordLevel = Self.estimatedFlag(in: row)
                let prices = Self.fuelDefinitions.compactMap { definition -> FuelPrice? in
                    guard let rawValue = row[definition.key] ?? row[definition.alternateKey],
                          let parsed = Self.price(from: rawValue) else { return nil }
                    let extraEstimated = Self.boolean(row[definition.key + "_estimated"]) ?? false
                    return FuelPrice(id: definition.key,
                                     title: definition.title,
                                     amount: parsed.amount,
                                     isEstimated: parsed.isEstimated || estimatedAtRecordLevel || extraEstimated)
                }
                let report = FuelPriceReport(prices: prices,
                                             source: Self.string(row["source"]),
                                             reportedAt: Self.string(row["reported_at"] ?? row["last_updated"]) ?? generatedAt)
                parsedPrices[stationID.lowercased()] = report
            }

            stations = stationRows.compactMap { row in
                guard let id = Self.string(row["id"]), !id.isEmpty,
                      let latitude = Self.number(row["lat"] ?? row["latitude"]),
                      let longitude = Self.number(row["lng"] ?? row["lon"] ?? row["longitude"]),
                      (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
                let rawType = Self.string(row["osm_type"] ?? row["type"])
                return Station(id: id,
                               osmID: Self.osmID(from: row["osm_id"]) ?? Self.osmID(from: id),
                               osmType: Self.normalizedOSMType(rawType) ?? Self.typeFromStationID(id),
                               name: Self.string(row["name"]),
                               brand: Self.string(row["brand"]),
                               coordinate: Coordinate(latitude: latitude, longitude: longitude))
            }
            prices = parsedPrices
            guard !stations.isEmpty, !prices.isEmpty else { throw FuelPriceProviderError.invalidResponse }
        }

        private static let fuelDefinitions: [(key: String, alternateKey: String, title: String)] = [
            ("pb95", "pb_95", "Pb95"),
            ("pb98", "pb_98", "Pb98"),
            ("on", "diesel", "ON"),
            ("lpg", "lpg", "LPG")
        ]

        private static func rootObject(from data: Data) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FuelPriceProviderError.invalidResponse
            }
            return object
        }

        private static func records(in root: [String: Any], key: String) -> [[String: Any]] {
            if let records = root[key] as? [[String: Any]] { return records }
            if let data = root["data"] as? [String: Any], let records = data[key] as? [[String: Any]] {
                return records
            }
            return []
        }

        private static func string(_ value: Any?) -> String? {
            guard let value, !(value is NSNull) else { return nil }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }

        private static func number(_ value: Any?) -> Double? {
            guard let value, !(value is NSNull) else { return nil }
            if let number = value as? NSNumber { return number.doubleValue }
            guard let string = value as? String else { return nil }
            let digits = string.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
            guard !digits.isEmpty else { return nil }
            let normalized = digits.contains(".") ? digits.replacingOccurrences(of: ",", with: "") : digits.replacingOccurrences(of: ",", with: ".")
            guard let parsed = Double(normalized), parsed.isFinite else { return nil }
            return parsed
        }

        private static func price(from raw: Any) -> (amount: Double, isEstimated: Bool)? {
            if let object = raw as? [String: Any] {
                guard let amount = number(object["price"] ?? object["amount"] ?? object["value"]), amount > 0 else { return nil }
                return (amount, estimatedFlag(in: object))
            }
            guard let amount = number(raw), amount > 0 else { return nil }
            let isEstimated = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("~") ?? false
            return (amount, isEstimated)
        }

        private static func estimatedFlag(in object: [String: Any]) -> Bool {
            if boolean(object["estimated"]) == true || boolean(object["is_estimated"]) == true { return true }
            if boolean(object["verified"]) == false || boolean(object["is_verified"]) == false { return true }
            let confidence = string(object["confidence"] ?? object["status"] ?? object["quality"] ?? object["source"])?.lowercased()
            return confidence?.contains("estimate") == true || confidence == "approximate"
        }

        private static func boolean(_ value: Any?) -> Bool? {
            guard let value else { return nil }
            if let number = value as? NSNumber { return number.boolValue }
            guard let string = value as? String else { return nil }
            switch string.lowercased() {
            case "true", "yes", "1", "estimated", "approximate": return true
            case "false", "no", "0", "verified": return false
            default: return nil
            }
        }

        private static func osmID(from value: Any?) -> Int64? {
            guard let string = string(value) else { return nil }
            if let numericID = Int64(string), numericID > 0 { return numericID }

            let normalized = string.lowercased()
            let prefixes = ["pl_", "pl-", "osm_", "osm-", "node/", "way/", "relation/", "node:", "way:", "relation:"]
            guard let prefix = prefixes.first(where: normalized.hasPrefix) else { return nil }
            let suffix = String(normalized.dropFirst(prefix.count))
            guard let numericID = Int64(suffix), numericID > 0 else { return nil }
            return numericID
        }

        private static func normalizedOSMType(_ value: String?) -> String? {
            guard let value else { return nil }
            switch value.lowercased() {
            case "n", "node": return "node"
            case "w", "way": return "way"
            case "r", "relation": return "relation"
            default: return nil
            }
        }

        private static func typeFromStationID(_ id: String) -> String? {
            let value = id.lowercased()
            if value.contains("node") { return "node" }
            if value.contains("way") { return "way" }
            if value.contains("relation") { return "relation" }
            return nil
        }
    }

    nonisolated private struct Station: Sendable {
        let id: String
        let osmID: Int64?
        let osmType: String?
        let name: String?
        let brand: String?
        let coordinate: Coordinate
    }
}

enum FuelPriceProviderError: Error {
    case unavailable
    case invalidResponse
}
