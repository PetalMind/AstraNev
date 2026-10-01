import Foundation

struct NavigationSessionDependencies {
    let routeProvider: RouteProvider
    let transitProvider: TransitRouteProvider
    let transitDataProvider: TransitDataProviding
    let speedLimitProvider: SpeedLimitProvider
    let roadDataProvider: RoadDataProvider
    let trafficProvider: TrafficProvider?
    let trafficProviderFactory: TrafficProviderFactory
    let voiceGuidance: VoiceGuidanceEngine

    static func live(routeEndpoint: URL, trafficAPIKey: String?,
                     transitProvider: TransitRouteProvider? = nil,
                     transitDataProvider: TransitDataProviding? = nil) -> NavigationSessionDependencies {
        let normalizedKey = trafficAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trafficProvider = normalizedKey.flatMap { $0.isEmpty ? nil : TomTomTrafficProvider(apiKey: $0) }
        let routing = NavigationRoutingDependencies.live(routeEndpoint: routeEndpoint,
                                                          transitProvider: transitProvider)
        return NavigationSessionDependencies(
            routeProvider: routing.routeProvider,
            transitProvider: routing.transitProvider,
            transitDataProvider: transitDataProvider ?? LocalTransitDataProvider(),
            speedLimitProvider: routing.speedLimitProvider,
            roadDataProvider: CombinedRoadDataProvider(),
            trafficProvider: trafficProvider,
            trafficProviderFactory: .tomTom,
            voiceGuidance: VoiceGuidanceEngine())
    }
}

struct NavigationRoutingDependencies {
    let routeProvider: RouteProvider
    let transitProvider: TransitRouteProvider
    let speedLimitProvider: SpeedLimitProvider

    static func live(routeEndpoint: URL,
                     transitProvider: TransitRouteProvider? = nil) -> NavigationRoutingDependencies {
        let configuredTransitProvider = transitProvider ?? TransitousRouteProvider()
        return NavigationRoutingDependencies(
            routeProvider: ValhallaRouteProvider(endpoint: routeEndpoint),
            transitProvider: configuredTransitProvider,
            speedLimitProvider: ValhallaSpeedLimitProvider(endpoint: routeEndpoint))
    }
}

struct TrafficProviderFactory {
    private let makeProvider: (String) -> TrafficProvider

    init(makeProvider: @escaping (String) -> TrafficProvider) {
        self.makeProvider = makeProvider
    }

    func make(apiKey: String?) -> TrafficProvider? {
        guard let apiKey else { return nil }
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return nil }
        return makeProvider(normalizedKey)
    }

    static let tomTom = TrafficProviderFactory { TomTomTrafficProvider(apiKey: $0) }
}
