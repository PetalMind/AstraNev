import Foundation

nonisolated struct TransitRegion: Sendable {
    let id: String
    let displayName: String
    let staticFeedFilename: String
    let staticFeedURL: URL
    let tripUpdatesURL: URL
    let alertsURL: URL
    let vehiclePositionsURL: URL
    let railwayFeedURL: URL
    let railwayTripUpdatesURL: URL
    let cacheDirectoryName: String
    let coverageCenter: Coordinate
    let coverageRadiusMeters: Double
    let dataPortalTitle: String
    let dataPortalURL: URL
    let scheduleTitle: String
    let scheduleURL: URL

    static let lodz = TransitRegion(
        id: "lodz",
        displayName: "Łódź",
        staticFeedFilename: "lodz-gtfs.zip",
        staticFeedURL: URL(string: "https://otwarte.miasto.lodz.pl/wp-content/uploads/2025/06/GTFS.zip")!,
        tripUpdatesURL: URL(string: "https://otwarte.miasto.lodz.pl/wp-content/uploads/2025/06/trip_updates.bin")!,
        alertsURL: URL(string: "https://otwarte.miasto.lodz.pl/wp-content/uploads/2025/06/alerts.bin")!,
        vehiclePositionsURL: URL(string: "https://otwarte.miasto.lodz.pl/wp-content/uploads/2025/06/vehicle_positions.bin")!,
        railwayFeedURL: URL(string: "https://mkuran.pl/gtfs/polish_trains.zip")!,
        railwayTripUpdatesURL: URL(string: "https://mkuran.pl/gtfs/polish_trains/updates.pb")!,
        cacheDirectoryName: "LodzTransit",
        coverageCenter: Coordinate(latitude: 51.7592, longitude: 19.4560),
        coverageRadiusMeters: 100_000,
        dataPortalTitle: "Otwarte dane Łódź",
        dataPortalURL: URL(string: "https://otwarte.miasto.lodz.pl/transport_komunikacja/")!,
        scheduleTitle: "Rozkłady MPK Łódź",
        scheduleURL: URL(string: "https://www.mpk.lodz.pl/rozklady/linie.jsp")!)
}
