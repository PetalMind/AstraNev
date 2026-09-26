import Foundation

struct NavigationEngineDependencies {
    let routeProvider: RouteProvider
    let transitProvider: LodzTransitRouteProvider
    let speedLimitProvider: SpeedLimitProvider
    let roadDataProvider: RoadDataProvider
    let trafficProvider: TrafficProvider?
    let voiceGuidance: VoiceGuidanceEngine

    static func live(routeEndpoint: URL, trafficAPIKey: String?) -> NavigationEngineDependencies {
        let normalizedKey = trafficAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trafficProvider = normalizedKey.flatMap { $0.isEmpty ? nil : TomTomTrafficProvider(apiKey: $0) }
        return NavigationEngineDependencies(
            routeProvider: ValhallaRouteProvider(endpoint: routeEndpoint),
            transitProvider: LodzTransitRouteProvider(walkingRoutingEndpoint: routeEndpoint),
            speedLimitProvider: ValhallaSpeedLimitProvider(endpoint: routeEndpoint),
            roadDataProvider: OpenStreetMapRoadDataProvider(),
            trafficProvider: trafficProvider,
            voiceGuidance: VoiceGuidanceEngine())
    }
}
