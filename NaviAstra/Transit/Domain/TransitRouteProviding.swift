import Foundation

protocol TransitRouteProvider: Sendable {
    var region: TransitRegion { get }

    func routes(
        from: Coordinate,
        to: Coordinate,
        time: Date,
        arriveBy: Bool,
        preferences: TransitRoutePreferences,
        cancellationToken: TransitPlanningCancellationToken?
    ) async throws -> [TransitJourney]
}

protocol TransitDataProviding: Sendable {
    var region: TransitRegion { get }

    func vehiclePositions(near coordinate: Coordinate) async -> TransitVehicleFeed
    func departures(at stopID: String, limit: Int) async -> [TransitDeparture]
    func departures(at stopIDs: [String], limit: Int) async -> [TransitDeparture]
    func alerts(for stopID: String) async -> [String]
    func alerts(for stopIDs: [String]) async -> [String]
    func railwayScheduleAttribution() async -> String?
    func search(_ query: String, near coordinate: Coordinate?) async -> TransitSearchResults
    func lineDetails(for routeID: String) async -> TransitLineDetails?
    func vehicleDetails(id: String) async -> TransitTripDetails?
    func tripDetails(for departure: TransitDeparture) async -> TransitTripDetails?
    func tripDetails(tripID: String, serviceDate: String,
                     fromStopSequence: Int) async -> TransitTripDetails?
    func tripDetails(tripID: String, serviceDate: String, fromStopSequence: Int,
                     scheduleShiftSeconds: Int, frequencyStartSeconds: Int?,
                     frequencyHeadwaySeconds: Int?, isFrequencyEstimate: Bool) async -> TransitTripDetails?
}

extension TransitDataProviding {
    func departures(at stopID: String) async -> [TransitDeparture] {
        await departures(at: stopID, limit: 10)
    }

    func departures(at stopIDs: [String]) async -> [TransitDeparture] {
        await departures(at: stopIDs, limit: 10)
    }

    func alerts(for stopID: String) async -> [String] {
        await alerts(for: [stopID])
    }
}

enum TransitRouteError: Error, LocalizedError, Equatable {
    case noRoute
    case network
    case timeout
    case invalidResponse
    case decoding
    case rateLimited(retryAfter: TimeInterval?)
    case serviceUnavailable
    case contactRequired

    var errorDescription: String? {
        switch self {
        case .noRoute:
            "Nie znaleziono połączenia dla wybranej godziny."
        case .network:
            "Nie udało się połączyć z usługą Transitous. Sprawdź połączenie z internetem."
        case .timeout:
            "Usługa Transitous nie odpowiedziała na czas. Spróbuj ponownie później."
        case .invalidResponse:
            "Usługa Transitous zwróciła nieprawidłową odpowiedź."
        case .decoding:
            "Nie udało się odczytać odpowiedzi usługi Transitous."
        case .rateLimited:
            "Transitous ograniczył liczbę żądań. Poczekaj przed kolejną próbą."
        case .serviceUnavailable:
            "Usługa Transitous jest chwilowo niedostępna."
        case .contactRequired:
            "Uzupełnij kontakt aplikacji wymagany przez Transitous."
        }
    }
}
