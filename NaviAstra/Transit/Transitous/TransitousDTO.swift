import Foundation

struct TransitousPlanResponseDTO: Decodable, Sendable {
    let itineraries: [TransitousItineraryDTO]
    let direct: [TransitousItineraryDTO]?
}

struct TransitousItineraryDTO: Decodable, Sendable {
    let duration: Int
    let startTime: String
    let endTime: String
    let transfers: Int
    let id: String
    let legs: [TransitousLegDTO]
}

struct TransitousLegDTO: Decodable, Sendable {
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

struct TransitousPlaceDTO: Decodable, Sendable {
    let name: String
    let stopId: String?
    let lat: Double
    let lon: Double
    let arrival: String?
    let departure: String?
    let scheduledArrival: String?
    let scheduledDeparture: String?
}

struct TransitousEncodedPolylineDTO: Decodable, Sendable {
    let points: String
    let precision: Int
    let length: Int
}

struct TransitousAlertDTO: Decodable, Sendable {
    let headerText: String
    let descriptionText: String
}
