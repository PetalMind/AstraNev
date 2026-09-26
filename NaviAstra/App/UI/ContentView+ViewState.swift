import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

extension ContentView {
    var mapCapabilities: MapProviderCapabilities { ActiveMapProvider.capabilities }

    var appSheetBinding: Binding<AppSheetDestination?> {
        Binding(get: { appRouter.sheet }, set: { appRouter.sheet = $0 })
    }

    @ViewBuilder
    func appSheet(_ destination: AppSheetDestination) -> some View {
        switch destination {
        case .search:
            searchSheet
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        case .originPicker:
            routeOriginPicker
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case .settings:
            settingsSheet
        case .routeSettings:
            routeSettingsSheet
        case .favorites:
            favoritesSheet
        case .history:
            historySheet
        case .trafficDetails:
            trafficDetailsSheet
        }
    }

    func handleAppSheetDismissal() {
        switch appRouter.consumeDismissedSheet() {
        case .search:
            selectingRouteOriginInSearch = false
        case .originPicker where openOriginSearchAfterPickerDismiss:
            openOriginSearchAfterPickerDismiss = false
            selectingRouteOriginInSearch = true
            appRouter.present(.search)
        default:
            break
        }
    }

    var plannedTransitLegForSelectedTrip: JourneyLeg? {
        guard let selectedTransitTripID else { return nil }
        return engine.state.route?.journey?.legs.first(where: { $0.tripID == selectedTransitTripID })
    }

    var transitLineCoordinatesForMap: [Coordinate] {
        if let plannedTransitLegForSelectedTrip { return plannedTransitLegForSelectedTrip.coordinates }
        if !selectedTransitTripCoordinates.isEmpty { return selectedTransitTripCoordinates }
        return selectedTransitLine?.coordinates ?? []
    }

    var transitStopIDsForMap: Set<String> {
        if let plannedTransitLegForSelectedTrip {
            return Set(plannedTransitLegForSelectedTrip.transitStops.map(\.stopID))
        }
        return selectedTransitTripStopIDs
    }

    var activeNavigationTransitLeg: JourneyLeg? {
        guard isNavigating, let legs = engine.state.route?.journey?.legs else { return nil }
        if let index = engine.state.transitProgress?.legIndex, legs.indices.contains(index) {
            if legs[index].mode != "WALK" { return legs[index] }
            return legs.dropFirst(index + 1).first { $0.mode != "WALK" }
        }
        return legs.first { $0.mode != "WALK" && $0.arrival > Date() }
    }

    var activeTransitStopID: String? {
        if let progress = engine.state.transitProgress,
           let legs = engine.state.route?.journey?.legs,
           legs.indices.contains(progress.legIndex), legs[progress.legIndex].mode != "WALK" {
            return progress.nextStop?.stopID
        }
        return activeNavigationTransitLeg?.transitStops.first?.stopID
    }

    var alightingTransitStopID: String? {
        activeNavigationTransitLeg?.transitStops.last?.stopID
    }

    var supportedBaseMap: Binding<String> {
        Binding(
            get: {
                let requested = BaseMap(rawValue: mapBase) ?? .standard
                return mapCapabilities.supports(requested) ? requested.rawValue : BaseMap.standard.rawValue
            },
            set: { value in
                guard let selected = BaseMap(rawValue: value), mapCapabilities.supports(selected) else { return }
                mapBase = selected.rawValue
            })
    }

    var mapSettings: MapSettings {
        let requestedBase = BaseMap(rawValue: mapBase) ?? .standard
        return MapSettings(
            baseMap: mapCapabilities.supports(requestedBase) ? requestedBase : .standard,
            appearance: MapAppearance(rawValue: mapAppearance) ?? .auto,
            cameraMode: mapCapabilities.supports3DCamera ? (MapDimension(rawValue: mapDimension) ?? .flat) : .flat,
            overlays: MapOverlays(
                traffic: mapCapabilities.supportsTrafficOverlay && mapTrafficVisible,
                poi: mapCapabilities.supportsPOIToggle && mapPOIVisible,
                buildings3D: mapCapabilities.supports3DBuildings && mapBuildingsVisible,
                transit: mapCapabilities.supportsTransitOverlay && mapTransitVisible,
                cycling: mapCapabilities.supportsCyclingOverlay && mapCyclingVisible),
            poiCategories: Set(MapPOICategory.allCases.filter { mapPOICategories & $0.mask != 0 }))
    }

    var navigationMapSettings: MapSettings {
        var settings = mapSettings
        if engine.state.destination != nil && engine.state.status != .idle {
            let shouldShowContextualPOI = isNavigating || engine.state.status == .arrived
            if !shouldShowContextualPOI { settings.overlays.poi = false }
        }
        if isNavigating || engine.state.status == .arrived {
            if engine.state.status == .arrived || (engine.state.progress?.remainingDistance ?? .infinity) < 500 {
                settings.context = .approachingDestination
            } else {
                switch engine.state.transportMode {
                case .car: settings.context = .driving
                case .walking: settings.context = .walking
                case .bicycle: settings.context = .cycling
                case .transit: settings.context = .transit
                case .parkRide:
                    if let leg = activeParkRideLeg {
                        switch leg.mode.uppercased() {
                        case "CAR": settings.context = .driving
                        case "WALK": settings.context = .walking
                        default: settings.context = .transit
                        }
                    } else {
                        settings.context = .driving
                    }
                }
            }
        }
        return settings
    }

    var isNavigating: Bool {
        engine.state.status == .navigating || engine.state.status == .rerouting
    }

    var activeParkRideLeg: JourneyLeg? {
        guard let legs = engine.state.route?.journey?.legs, !legs.isEmpty else { return nil }
        if let index = engine.state.transitProgress?.legIndex, legs.indices.contains(index) {
            return legs[index]
        }
        return legs.first { $0.arrival > Date() } ?? legs.last
    }

    var parkRideIsUsingTransitLeg: Bool {
        guard let activeParkRideLeg else { return false }
        return activeParkRideLeg.mode.uppercased() != "CAR"
    }

    var parkRideIsDrivingLeg: Bool {
        activeParkRideLeg?.mode.uppercased() == "CAR"
    }

    var isOnRoadDrivingLeg: Bool {
        engine.state.transportMode == .car ||
            (engine.state.transportMode == .parkRide && parkRideIsDrivingLeg)
    }

    var activeJourneyNearbyCategories: [NearbyPlaceCategory] {
        switch engine.state.transportMode {
        case .car:
            [.fuel, .parking, .charging, .food]
        case .parkRide where parkRideIsDrivingLeg:
            [.fuel, .parking, .charging, .food]
        case .walking, .bicycle, .transit, .parkRide:
            [.food]
        }
    }

    var supportsActiveTripWaypoints: Bool {
        switch engine.state.transportMode {
        case .car, .walking, .bicycle: true
        case .transit, .parkRide: false
        }
    }

    var supportsActiveTripTrafficDetails: Bool {
        engine.state.transportMode == .car
    }

    var supportsActiveTripDestinationParking: Bool {
        engine.state.transportMode == .car
    }

    var supportsActiveTripRoadPreferences: Bool {
        isOnRoadDrivingLeg
    }

    var parkRideCarDistanceToTransfer: Double? {
        guard engine.state.transportMode == .parkRide,
              parkRideIsDrivingLeg,
              let location = engine.state.location,
              let coordinates = activeParkRideLeg?.coordinates,
              coordinates.count > 1,
              let projection = MapMatcher.project(location.coordinate, onto: coordinates),
              projection.distanceFromRoute <= max(150, location.accuracy * 2) else { return nil }
        let legLength = zip(coordinates, coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        return max(0, legLength - projection.alongRoute)
    }

    var activeJourneyTargetText: String {
        let fallback = currentJourneyLeg?.current.name ?? engine.state.destination?.name ?? "celu"
        switch engine.state.transportMode {
        case .car:
            return "Teraz jedziesz do \(fallback)"
        case .walking:
            return "Teraz idziesz do \(fallback)"
        case .bicycle:
            return "Teraz jedziesz rowerem do \(fallback)"
        case .transit:
            guard let leg = activeTransitLeg else { return "Teraz podróżujesz do \(fallback)" }
            return leg.mode == "WALK"
                ? "Teraz idziesz do \(leg.to)"
                : "Teraz jedziesz linią \(leg.line ?? "MPK") do \(leg.to)"
        case .parkRide:
            guard let leg = activeParkRideLeg else { return "Teraz podróżujesz do \(fallback)" }
            if leg.mode == "WALK" { return "Teraz idziesz do \(leg.to)" }
            if leg.mode == "CAR" { return "Teraz jedziesz samochodem do \(leg.to)" }
            return "Teraz jedziesz linią \(leg.line ?? "MPK") do \(leg.to)"
        }
    }

    var arrivalTitle: String {
        switch engine.state.transportMode {
        case .car: "Cel osiągnięty samochodem!"
        case .walking: "Cel osiągnięty pieszo!"
        case .bicycle: "Cel osiągnięty rowerem!"
        case .transit: "Cel osiągnięty komunikacją miejską!"
        case .parkRide: "Cel osiągnięty w systemie P+R!"
        }
    }

    var arrivalDistanceCaption: String {
        switch engine.state.transportMode {
        case .car: "samochodem"
        case .walking: "pieszo"
        case .bicycle: "rowerem"
        case .transit: "komunikacją"
        case .parkRide: "trasą P+R"
        }
    }

    var arrivalSummaryMetric: (symbol: String, value: String, caption: String) {
        let trip = engine.state.lastTrip
        switch engine.state.transportMode {
        case .walking:
            let pace = trip.flatMap { trip -> String? in
                guard trip.distanceMeters > 0, trip.movingSeconds > 0 else { return nil }
                let minutesPerKilometer = Int(ceil(trip.movingSeconds / (trip.distanceMeters / 1_000) / 60))
                return "\(minutesPerKilometer) min/km"
            } ?? "—"
            return ("figure.walk", pace, "tempo")
        case .transit:
            guard let transfers = engine.state.route?.journey?.transferCount else {
                return ("arrow.left.arrow.right", "—", "przesiadek")
            }
            return ("arrow.left.arrow.right", "\(transfers)", transferCaption(transfers))
        case .parkRide:
            guard let journeyTransfers = engine.state.route?.journey?.transferCount else {
                return ("arrow.left.arrow.right", "—", "przesiadek")
            }
            let transfers = journeyTransfers + 1
            return ("arrow.left.arrow.right", "\(transfers)", transferCaption(transfers))
        case .car, .bicycle:
            let symbol = engine.state.transportMode == .car ? "car.side" : "bicycle"
            let speed = trip.map { "\(Int($0.averageSpeedKph.rounded())) km/h" } ?? "—"
            return (symbol, speed, "śr. prędkość")
        }
    }

    var navigationArrivalCaption: String {
        switch engine.state.transportMode {
        case .walking, .bicycle: "dotarcie"
        case .car, .transit, .parkRide: "przyjazd"
        }
    }

    func transferCaption(_ count: Int) -> String {
        let lastTwoDigits = count % 100
        let lastDigit = count % 10
        if lastDigit == 1, lastTwoDigits != 11 { return "przesiadka" }
        if (2...4).contains(lastDigit), !(12...14).contains(lastTwoDigits) { return "przesiadki" }
        return "przesiadek"
    }

    var usesFullBleedNavigationPanel: Bool {
        #if os(iOS)
        isNavigating || engine.state.status == .arrived || isIOSRoutePlanningPreview
        #else
        false
        #endif
    }

    var isIOSRoutePlanningPreview: Bool {
        #if os(iOS)
        engine.state.destination != nil &&
            (engine.state.status == .routePreview || engine.state.status == .error)
        #else
        false
        #endif
    }

    var arrivalShareURL: URL? {
        guard let destination = engine.state.destination else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        var queryItems = [URLQueryItem]()
        if let origin = engine.state.route?.coordinates.first {
            queryItems.append(URLQueryItem(
                name: "saddr",
                value: "\(origin.latitude),\(origin.longitude)"))
        }
        queryItems.append(URLQueryItem(
            name: "daddr",
            value: "\(destination.coordinate.latitude),\(destination.coordinate.longitude)"))
        switch engine.state.transportMode {
        case .car, .parkRide: queryItems.append(URLQueryItem(name: "dirflg", value: "d"))
        case .walking: queryItems.append(URLQueryItem(name: "dirflg", value: "w"))
        case .bicycle: break
        case .transit: queryItems.append(URLQueryItem(name: "dirflg", value: "r"))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    var availablePolishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "pl-PL" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var voiceEnabledBinding: Binding<Bool> {
        Binding(
            get: { engine.state.voiceEnabled },
            set: { engine.setVoiceEnabled($0) })
    }

    var voiceVerbosityBinding: Binding<VoiceVerbosity> {
        Binding(
            get: { engine.state.voicePreferences.verbosity },
            set: { value in updateVoicePreferences { $0.verbosity = value } })
    }

    var voiceIdentifierBinding: Binding<String> {
        Binding(
            get: {
                let identifier = engine.state.voicePreferences.voiceIdentifier ?? ""
                return availablePolishVoices.contains(where: { $0.identifier == identifier }) ? identifier : ""
            },
            set: { value in updateVoicePreferences { $0.voiceIdentifier = value.isEmpty ? nil : value } })
    }

    var voiceRateBinding: Binding<Double> {
        Binding(
            get: { Double(engine.state.voicePreferences.speechRate) },
            set: { value in updateVoicePreferences { $0.speechRate = Float(value) } })
    }

    var voiceVolumeBinding: Binding<Double> {
        Binding(
            get: { Double(engine.state.voicePreferences.volume) },
            set: { value in updateVoicePreferences { $0.volume = Float(value) } })
    }

    func updateVoicePreferences(_ update: (inout VoiceGuidancePreferences) -> Void) {
        var preferences = engine.state.voicePreferences
        update(&preferences)
        engine.setVoicePreferences(preferences)
    }

    var hasRoutePreviewContext: Bool {
        engine.state.destination != nil && !isNavigating &&
            (engine.state.status == .routePreview || engine.state.status == .routeCalculating || engine.state.status == .error)
    }

    var isTransitRoutePreview: Bool {
        engine.state.status == .routePreview && engine.state.transportMode == .transit
    }

    var isDestinationFavorite: Bool {
        guard let destination = engine.state.destination else { return false }
        return localData.places.contains {
            $0.kind == .favorite && $0.destination.coordinate == destination.coordinate
        }
    }

    var routeOriginPoint: RoutePoint? {
        engine.state.routeOrigin ?? engine.state.location.map {
            RoutePoint(Destination(name: "Twoja lokalizacja", coordinate: $0.coordinate),
                       source: .currentLocation)
        }
    }

    var isRouteOriginAwayFromUser: Bool {
        guard let origin = engine.state.routeOrigin, !origin.isCurrentLocation else { return false }
        guard let location = engine.state.location else { return true }
        return origin.coordinate.distance(to: location.coordinate) > 100
    }

    var pointSelectionHint: String {
        #if os(macOS)
        "Wyszukaj adres lub miejsce albo kliknij dwukrotnie mapę, aby wybrać punkt."
        #else
        "Wyszukaj adres lub miejsce albo przytrzymaj mapę, aby wybrać punkt."
        #endif
    }
}
