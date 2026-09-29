import Foundation

nonisolated struct TransitousPlanResponseDTO: Decodable, Sendable {
    let itineraries: [TransitousItineraryDTO]
    let direct: [TransitousItineraryDTO]?
}

nonisolated struct TransitousItineraryDTO: Decodable, Sendable {
    let duration: Int
    let startTime: String
    let endTime: String
    let transfers: Int
    let id: String
    let legs: [TransitousLegDTO]
}

nonisolated struct TransitousLegDTO: Decodable, Sendable {
    let mode: String
    let from: TransitousPlaceDTO
    let to: TransitousPlaceDTO
    let duration: Int
    let startTime: String
    let endTime: String
    let scheduledStartTime: String
    let scheduledEndTime: String
    let realTime: Bool
    let distance: Double?
    let interlineWithPreviousLeg: Bool?
    let headsign: String?
    let tripTo: TransitousPlaceDTO?
    let routeId: String?
    let routeColor: String?
    let agencyName: String?
    let tripId: String?
    let routeShortName: String?
    let routeLongName: String?
    let tripShortName: String?
    let displayName: String?
    let cancelled: Bool?
    let intermediateStops: [TransitousPlaceDTO]?
    let legGeometry: TransitousEncodedPolylineDTO
    let alerts: [TransitousAlertDTO]?
}

nonisolated struct TransitousPlaceDTO: Decodable, Sendable {
    let name: String
    let stopId: String?
    let parentId: String?
    let lat: Double
    let lon: Double
    let importance: Double?
    let modes: [String]?
    let tz: String?
    let arrival: String?
    let departure: String?
    let scheduledArrival: String?
    let scheduledDeparture: String?
    let alerts: [TransitousAlertDTO]?
}

nonisolated struct TransitousGeocodeMatchDTO: Decodable, Sendable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let modes: [String]?
    let importance: Double?
}

nonisolated struct TransitousStopTimesResponseDTO: Decodable, Sendable {
    let stopTimes: [TransitousStopTimeDTO]
    let place: TransitousPlaceDTO
    let previousPageCursor: String?
    let nextPageCursor: String?
}

nonisolated struct TransitousStopTimeDTO: Decodable, Sendable {
    let place: TransitousPlaceDTO
    let mode: String?
    let realTime: Bool?
    let headsign: String?
    let tripTo: TransitousPlaceDTO?
    let agencyName: String?
    let tripId: String?
    let routeId: String?
    let routeColor: String?
    let routeShortName: String?
    let routeLongName: String?
    let displayName: String?
    let cancelled: Bool?
    let tripCancelled: Bool?
}

nonisolated struct TransitousStopInfoResponseDTO: Decodable, Sendable {
    let place: TransitousPlaceDTO
    let routes: [TransitousRouteDTO]
}

nonisolated struct TransitousRouteDTO: Decodable, Sendable {
    let routeId: String
    let routeShortName: String
    let routeLongName: String
    let mode: String
    let agencyName: String
    let routeColor: String?
}

nonisolated struct TransitousEncodedPolylineDTO: Decodable, Sendable {
    let points: String
    let precision: Int
    let length: Int
}

nonisolated struct TransitousAlertDTO: Decodable, Sendable {
    let headerText: String
    let descriptionText: String
}
