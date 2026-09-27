import Foundation

actor TransitRepository {
    static let maximumDepartureSearchWindow: TimeInterval = 18 * 60 * 60

    let region: TransitRegion
    var staticFeedURL: URL { region.staticFeedURL }
    var tripUpdatesURL: URL { region.tripUpdatesURL }
    var alertsURL: URL { region.alertsURL }
    var vehiclePositionsURL: URL { region.vehiclePositionsURL }
    var railwayFeedURL: URL { region.railwayFeedURL }
    var railwayTripUpdatesURL: URL { region.railwayTripUpdatesURL }
    var cacheDirectory: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(region.cacheDirectoryName, isDirectory: true)
    }

    init(region: TransitRegion = .lodz) {
        self.region = region
    }
    var compiledDatabaseURL: URL {
        cacheDirectory.appendingPathComponent("compiled-transit-index-v4.plist")
    }
    var legacyCompiledDatabaseURL: URL {
        cacheDirectory.appendingPathComponent("compiled-transit-index-v3.plist")
    }
    var database: GTFSDatabase?
    var databaseLoadedAt: Date?
    var databaseLoadTask: Task<LoadedTransitDatabase, Error>?
    var realtimeSnapshot: GTFSRealtimeSnapshot?
    var realtimeLoadedAt: Date?
    var realtimeLoadTask: Task<GTFSRealtimeSnapshot, Never>?
    var vehiclesSnapshot: [GTFSRealtimeVehicle] = []
    var vehiclesUpdatedAt: Date?
    var vehiclesLoadedAt: Date?
    var loadedDatabaseFingerprint: String?

}
