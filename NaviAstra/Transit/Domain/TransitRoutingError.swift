import Foundation

nonisolated enum TransitRoutingError: LocalizedError {
    case invalidResponse
    case noJourney
    case noJourneyBeforeArrivalDeadline
    case noParkRide
    case walkingUnavailable
    case walkingServerError(Int)
    case walkingRateLimited
    case feedUnavailable
    case railwayFeedUnavailable
    case outsideCoverage

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Źródło rozkładów zwróciło nieprawidłowe dane."
        case .noJourney:
            "Nie znaleziono połączenia kolejowego ani komunikacji publicznej dla wybranej godziny."
        case .noJourneyBeforeArrivalDeadline:
            "Nie znaleziono połączenia, które dotrze przed wybraną godziną."
        case .noParkRide:
            "Nie udało się znaleźć działającego połączenia z parkingu P+R."
        case .walkingUnavailable:
            "Nie udało się wyznaczyć dojścia pieszo do przystanków przez serwer Valhalla."
        case .walkingServerError(let statusCode):
            "Serwer tras odrzucił wyznaczenie dojścia (HTTP \(statusCode))."
        case .walkingRateLimited:
            "Serwer tras ograniczył liczbę żądań. Poczekaj chwilę i spróbuj ponownie."
        case .feedUnavailable:
            "Nie udało się pobrać rozkładu jazdy komunikacji publicznej."
        case .railwayFeedUnavailable:
            "Krajowy rozkład kolejowy jest chwilowo niedostępny. Spróbuj ponownie za chwilę."
        case .outsideCoverage:
            "Pobrany rozkład nie zawiera obsługiwanego przystanku dla początku lub celu podróży."
        }
    }
}
