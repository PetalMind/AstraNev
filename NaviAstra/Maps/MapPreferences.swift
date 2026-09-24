import Foundation

enum BaseMap: String, CaseIterable, Identifiable {
    case standard, satellite, terrain
    var id: String { rawValue }
    var title: String {
        switch self { case .standard: "Standard"; case .satellite: "Satelitarna"; case .terrain: "Terenowa" }
    }
}

enum MapAppearance: String, CaseIterable, Identifiable {
    case day, night, auto
    var id: String { rawValue }
    var title: String {
        switch self { case .day: "Dzień"; case .night: "Noc"; case .auto: "Auto" }
    }


}

enum MapDimension: String, CaseIterable, Identifiable {
    case flat, threeD
    var id: String { rawValue }
    var title: String { self == .flat ? "2D" : "3D" }
}

struct MapOverlays {
    var traffic: Bool
    var poi: Bool
    var buildings3D: Bool
    var transit: Bool
    var cycling: Bool
}

struct MapSettings {
    var baseMap: BaseMap
    var appearance: MapAppearance
    var cameraMode: MapDimension
    var overlays: MapOverlays
    var poiCategories: Set<MapPOICategory> = Set(MapPOICategory.allCases)
    var context: MapDisplayContext = .browse
}

struct MapProviderCapabilities {
    var supportsSatellite: Bool
    var supportsTerrain: Bool
    var supportsPOIToggle: Bool
    var supports3DBuildings: Bool
    var supportsTransitOverlay: Bool
    var supportsCyclingOverlay: Bool
    var supportsApplicationDarkMode: Bool
    var supportsMapDarkStyle: Bool
    var supportsTrafficOverlay: Bool
    var supports3DCamera: Bool

    func supports(_ baseMap: BaseMap) -> Bool {
        switch baseMap {
        case .standard: true
        case .satellite: supportsSatellite
        case .terrain: supportsTerrain
        }
    }
}

enum ActiveMapProvider {
    static var capabilities: MapProviderCapabilities {
        #if os(macOS)
        MapProviderCapabilities(supportsSatellite: true, supportsTerrain: true,
                                supportsPOIToggle: true, supports3DBuildings: true,
                                supportsTransitOverlay: false, supportsCyclingOverlay: false,
                                supportsApplicationDarkMode: true, supportsMapDarkStyle: true,
                                supportsTrafficOverlay: true, supports3DCamera: true)
        #else
        MapProviderCapabilities(supportsSatellite: false, supportsTerrain: false,
                                supportsPOIToggle: true, supports3DBuildings: true,
                                supportsTransitOverlay: true, supportsCyclingOverlay: false,
                                supportsApplicationDarkMode: true, supportsMapDarkStyle: true,
                                supportsTrafficOverlay: true, supports3DCamera: true)
        #endif
    }
}

/// Categories available in the vector tile schema, filtered before applying the travel context.
enum MapPOICategory: Int, CaseIterable, Identifiable {
    case fuel, parking, charging, food, shopping, health, attractions, transit, lodging
    var id: Int { rawValue }
    var mask: Int { 1 << rawValue }
    static var allMask: Int { allCases.reduce(0) { $0 | $1.mask } }
    var title: String {
        switch self {
        case .fuel: "Stacje paliw"
        case .parking: "Parkingi"
        case .charging: "Ładowarki"
        case .food: "Restauracje i kawiarnie"
        case .shopping: "Sklepy"
        case .health: "Szpitale i apteki"
        case .attractions: "Atrakcje i kultura"
        case .transit: "Przystanki i stacje"
        case .lodging: "Noclegi"
        }
    }
    var tileValues: [String] {
        switch self {
        case .fuel: ["fuel"]
        case .parking: ["parking"]
        case .charging: ["charging_station"]
        case .food: ["food", "restaurant", "cafe", "fast_food", "bar", "pub", "bakery"]
        case .shopping: ["shop", "grocery", "supermarket", "mall", "clothes", "convenience"]
        case .health: ["hospital", "pharmacy", "doctor", "doctors", "clinic"]
        case .attractions: ["attraction", "museum", "monument", "viewpoint", "castle", "theatre", "park"]
        case .transit: ["bus", "rail", "railway", "station", "bus_stop", "tram_stop", "subway", "airport"]
        case .lodging: ["lodging", "hotel", "hostel", "motel", "guest_house", "camp_site"]
        }
    }
}

enum MapDisplayContext: String {
    case browse, driving, walking, cycling, transit, approachingDestination
    var isNavigating: Bool { self != .browse }
    var relevantCategories: Set<MapPOICategory> {
        switch self {
        case .browse: Set(MapPOICategory.allCases)
        case .driving: [.fuel, .parking, .charging, .health]
        case .walking: [.food, .shopping, .attractions, .transit, .health, .lodging]
        case .cycling: [.food, .attractions, .health]
        case .transit: [.transit, .food]
        case .approachingDestination: [.parking, .transit, .charging]
        }
    }
}

extension MapSettings {
    var visiblePOICategories: Set<MapPOICategory> {
        overlays.poi ? poiCategories.intersection(context.relevantCategories) : []
    }
}
