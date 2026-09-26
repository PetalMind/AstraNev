import Foundation

struct FuelStationLookup: Sendable {
    let coordinate: Coordinate
    let countryCode: String?

    init(identity: PlaceIdentity) {
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
    let source: String
    let reportedAt: String
    let notes: String
    let isStale: Bool
}

enum FuelPriceLookupResult: Sendable {
    case outsideCoverage
    case prices(FuelPriceReport)
}

protocol FuelPriceProvider: Sendable {
    func prices(for station: FuelStationLookup) async throws -> FuelPriceLookupResult
    func pricesForPoland() async throws -> FuelPriceReport
}

actor FuelWideFuelPriceProvider: FuelPriceProvider {
    static let shared = FuelWideFuelPriceProvider()

    private var cachedReport: FuelPriceReport?
    private var cacheExpiresAt = Date.distantPast
    private var pendingReport: Task<FuelPriceReport, Error>?

    func prices(for station: FuelStationLookup) async throws -> FuelPriceLookupResult {
        guard isWithinPoland(station.coordinate, countryCode: station.countryCode) else {
            return .outsideCoverage
        }
        return .prices(try await pricesForPoland())
    }

    func pricesForPoland() async throws -> FuelPriceReport {
        if let cachedReport, cacheExpiresAt > Date() { return cachedReport }

        let task: Task<FuelPriceReport, Error>
        if let pendingReport {
            task = pendingReport
        } else {
            task = Task { try await Self.fetchReport() }
            pendingReport = task
        }

        do {
            let report = try await task.value
            cachedReport = report
            cacheExpiresAt = Date().addingTimeInterval(60 * 60)
            pendingReport = nil
            return report
        } catch {
            pendingReport = nil
            throw error
        }
    }

    private func isWithinPoland(_ coordinate: Coordinate, countryCode: String?) -> Bool {
        if let countryCode {
            let normalizedCountry = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalizedCountry.isEmpty && normalizedCountry != "pl" { return false }
        }
        return (49.0...55.2).contains(coordinate.latitude) && (14.0...24.2).contains(coordinate.longitude)
    }

    nonisolated private static func fetchReport() async throws -> FuelPriceReport {
        let fuelPricesURL = URL(string: "https://fuelwide.com/api/fuel-prices/poland")!
        let exchangeRateURL = URL(string: "https://api.nbp.pl/api/exchangerates/rates/a/eur/?format=json")!
        async let fuelPricesData = download(fuelPricesURL)
        async let exchangeRateData = download(exchangeRateURL)
        let (pricesData, rateData) = try await (fuelPricesData, exchangeRateData)

        let snapshot = try JSONDecoder().decode(FuelWideResponse.self, from: pricesData)
        let exchangeRate = try JSONDecoder().decode(NBPExchangeRateResponse.self, from: rateData)

        guard snapshot.country.iso2.uppercased() == "PL",
              snapshot.country.currency.uppercased() == "PLN",
              snapshot.unit.localizedCaseInsensitiveContains("EUR per litre"),
              let rate = exchangeRate.rates.first,
              rate.code == "EUR",
              rate.mid.isFinite,
              rate.mid > 0,
              let attribution = snapshot.attribution?.trimmingCharacters(in: .whitespacesAndNewlines),
              !attribution.isEmpty else {
            throw FuelPriceProviderError.invalidResponse
        }

        var pricesByFuel: [String: FuelPrice] = [:]
        for observation in snapshot.observations {
            guard let definition = FuelDefinition.byAPIType[observation.fuelType],
                  observation.currency.uppercased() == "EUR",
                  observation.unit.lowercased() == "litre",
                  observation.priceBasis == "national_weighted_average",
                  observation.geographicPrecision == "national",
                  observation.source.id == "ec-weekly-oil-bulletin",
                  observation.price.isFinite,
                  observation.price > 0 else { continue }

            pricesByFuel[observation.fuelType] = FuelPrice(
                id: observation.fuelType,
                title: definition.title,
                amount: observation.price * rate.mid,
                isEstimated: true
            )
        }

        guard let petrol95 = pricesByFuel["petrol95"],
              let diesel = pricesByFuel["diesel"] else {
            throw FuelPriceProviderError.invalidResponse
        }

        let acceptedObservations = snapshot.observations.filter {
            pricesByFuel[$0.fuelType] != nil
        }
        let observedAtValues = Set(acceptedObservations.map(\.observedAt))
        guard observedAtValues.count == 1,
              let observedAt = observedAtValues.first,
              !observedAt.isEmpty else {
            throw FuelPriceProviderError.invalidResponse
        }

        let isStale = acceptedObservations.contains { $0.stale }
        let datedObservation = Self.polishDate(observedAt)
        let datedExchangeRate = Self.polishDate(rate.effectiveDate)
        let note = "Średnia krajowa ważona, nie cena tej stacji. Wartości w zł przeliczono z euro po średnim kursie NBP."

        return FuelPriceReport(
            prices: [petrol95, diesel] + (pricesByFuel["lpg"].map { [$0] } ?? []),
            source: attribution,
            reportedAt: "Tydzień \(datedObservation) · kurs NBP z \(datedExchangeRate)",
            notes: note,
            isStale: isStale
        )
    }

    nonisolated private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
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

    nonisolated private static func polishDate(_ isoDate: String) -> String {
        let components = isoDate.split(separator: "-")
        guard components.count == 3 else { return isoDate }
        return "\(components[2]).\(components[1]).\(components[0])"
    }
}

private struct FuelDefinition: Sendable {
    let title: String

    static let byAPIType = [
        "petrol95": FuelDefinition(title: "Pb95"),
        "diesel": FuelDefinition(title: "ON"),
        "lpg": FuelDefinition(title: "LPG")
    ]
}

private struct FuelWideResponse: Decodable {
    let unit: String
    let country: Country
    let observations: [Observation]
    let attribution: String?

    struct Country: Decodable {
        let iso2: String
        let currency: String
    }

    struct Observation: Decodable {
        let fuelType: String
        let price: Double
        let currency: String
        let unit: String
        let priceBasis: String
        let geographicPrecision: String
        let observedAt: String
        let stale: Bool
        let source: Source
    }

    struct Source: Decodable {
        let id: String
    }
}

private struct NBPExchangeRateResponse: Decodable {
    let rates: [Rate]

    struct Rate: Decodable {
        let effectiveDate: String
        let mid: Double
        let code: String
    }
}

enum FuelPriceProviderError: Error {
    case unavailable
    case invalidResponse
}
