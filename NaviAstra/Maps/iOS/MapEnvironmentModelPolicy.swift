#if os(iOS)
import Foundation

/// Physical scale stays unchanged. Small projected objects use a coarse source
/// mesh; subpixel objects retain the map's existing fallback presentation.
struct MapEnvironmentModelPolicy {
    static let minimumZoom = 15.0
    let navigating: Bool
    let constrained: Bool
    var entrySpan: Double { navigating ? 1.8 : 2.8 }
    var retainedSpan: Double { navigating ? 1.3 : 2.0 }
    var standardSpan: Double { navigating ? 5 : 7 }
    var fullSpan: Double { navigating ? 14 : 16 }
    var buildingSpan: Double { navigating ? 7 : 11 }
    var detailedBuildingSpan: Double { constrained ? .infinity : (navigating ? 58 : 44) }
    var maximumBuildings: Int { constrained ? 20 : (navigating ? 72 : 64) }
    var buildingTriangles: Int { constrained ? 18_000 : (navigating ? 90_000 : 110_000) }
    var totalTriangles: Int { constrained ? 30_000 : (navigating ? 130_000 : 160_000) }
    var buildingReserve: Int { constrained ? 10_000 : 35_000 }
    var refreshInterval: TimeInterval { constrained ? 0.9 : (navigating ? 0.5 : 0.4) }
}
#endif
