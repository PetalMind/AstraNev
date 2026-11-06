#if os(iOS)
import Foundation
import Testing
@testable import NaviAstra

@Suite(.serialized)
@MainActor
struct VoiceSavedNavigationCriticalTests {
    @Test
    func explicitSavedCommandsStartWithoutAConfirmationQuestion() async throws {
        let cases: [(String, PlaceKind, String)] = [
            ("Prowadź do dom", .home, "Adres domu"),
            ("Prowadź do pracy", .work, "Adres pracy"),
            ("Prowadź do działki", .favorite, "Działki"),
            ("Prowadź do domu", .favorite, "Dom")
        ]
        for (utterance, kind, name) in cases {
            let destination = Destination(name: name, coordinate: .init(latitude: 52.02, longitude: 21))
            let fixture = try SavedVoiceFixture(places: [SavedPlace(destination: destination, kind: kind)])
            defer { fixture.close() }

            await fixture.submit(utterance)

            #expect(fixture.provider.requestCount == 1)
            #expect(fixture.session.state.destination?.id == destination.id)
            #expect(fixture.session.state.status == .navigating)
            #expect(!fixture.assistant.canConfirm)
            #expect(fixture.assistant.choices.isEmpty)
            #expect(fixture.replies.count == 1)
            #expect(fixture.replies.last?.hasPrefix("Prowadzę do ") == true)
            #expect(!fixture.replies.contains { $0.contains("?") })
        }
    }

    @Test
    func assignedHomeWinsOverAnUnrelatedFavoriteNamedHome() async throws {
        let assigned = Destination(name: "Właściwy adres", coordinate: .init(latitude: 52.02, longitude: 21))
        let favorite = Destination(name: "Dom", coordinate: .init(latitude: 52.03, longitude: 21))
        let fixture = try SavedVoiceFixture(places: [SavedPlace(destination: favorite),
                                                   SavedPlace(destination: assigned, kind: .home)])
        defer { fixture.close() }
        await fixture.submit("Prowadź do domu")
        #expect(fixture.session.state.destination?.id == assigned.id)
        #expect(fixture.session.state.status == .navigating)
        #expect(!fixture.assistant.canConfirm)
    }

    @Test
    func savedCommandStartsNowAfterAnEarlierFutureJourneyPlan() async throws {
        for timeMode in [JourneyTimeMode.departAt, .arriveBy] {
            let home = Destination(name: "Dom", coordinate: .init(latitude: 52.02, longitude: 21))
            let fixture = try SavedVoiceFixture(places: [SavedPlace(destination: home, kind: .home)])
            defer { fixture.close() }
            fixture.session.setJourneyTimeMode(timeMode)
            fixture.session.setJourneyTargetTime(.now.addingTimeInterval(86_400))
            let originalOrigin = fixture.session.state.routeOrigin

            await fixture.submit("Prowadź do domu")

            #expect(fixture.provider.requestCount == 1)
            #expect(fixture.session.state.journeyTimeMode == .now)
            #expect(fixture.session.state.journeyTargetTime < .now.addingTimeInterval(60))
            #expect(fixture.session.state.transportMode == .walking)
            #expect(fixture.session.state.routeOrigin == originalOrigin)
            #expect(fixture.session.state.destination?.id == home.id)
            #expect(fixture.session.state.status == .navigating)
            #expect(!fixture.assistant.canConfirm)
            #expect(fixture.replies.count == 1)
            #expect(fixture.replies.last?.hasPrefix("Prowadzę do ") == true)
            #expect(!fixture.replies.contains { $0.contains("Nie udało się") })
        }
    }

    @Test
    func duplicateSavedNamesStartRoutingAfterExplicitSelectionWithoutAnotherConfirmation() async throws {
        let first = Destination(name: "Działka", coordinate: .init(latitude: 52.02, longitude: 21), address: "Pierwszy adres")
        let second = Destination(name: "Działka", coordinate: .init(latitude: 52.03, longitude: 21), address: "Drugi adres")
        let fixture = try SavedVoiceFixture(places: [SavedPlace(destination: first), SavedPlace(destination: second)])
        defer { fixture.close() }

        await fixture.submit("Prowadź do działka")
        #expect(fixture.provider.requestCount == 0)
        #expect(fixture.session.state.destination == nil)
        #expect(fixture.assistant.canConfirm)
        #expect(fixture.assistant.choices.map(\.destination.id) == [first.id, second.id])

        let repliesBeforeChoice = fixture.replies.count
        await fixture.submit("Wybierz drugi")
        #expect(fixture.provider.requestCount == 1)
        #expect(fixture.session.state.destination?.id == second.id)
        #expect(fixture.session.state.status == .navigating)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.assistant.choices.isEmpty)
        #expect(fixture.replies.count == repliesBeforeChoice + 1)
        #expect(fixture.replies.last?.hasPrefix("Prowadzę do ") == true)
        #expect(fixture.replies.last?.contains("Drugi adres") == true)
        #expect(fixture.replies.last?.contains("?") == false)
    }

    @Test
    func missingHomeAndNegatedCommandDoNotStartNavigation() async throws {
        let missing = try SavedVoiceFixture(places: [])
        defer { missing.close() }
        await missing.submit("Prowadź do domu")
        #expect(missing.provider.requestCount == 0)
        #expect(missing.session.state.destination == nil)
        #expect(!missing.assistant.canConfirm)
        #expect(missing.replies.last?.contains("zapisz") == true)

        let destination = Destination(name: "Dom", coordinate: .init(latitude: 52.02, longitude: 21))
        let negated = try SavedVoiceFixture(places: [SavedPlace(destination: destination, kind: .home)])
        defer { negated.close() }
        await negated.submit("Nie prowadź do domu")
        #expect(negated.provider.requestCount == 0)
        #expect(negated.session.state.destination == nil)
        #expect(!negated.assistant.canConfirm)
    }

    @Test
    func failedSavedRouteDoesNotAnnounceSuccessfulGuidance() async throws {
        let destination = Destination(name: "Dom", coordinate: .init(latitude: 52.02, longitude: 21))
        let fixture = try SavedVoiceFixture(places: [SavedPlace(destination: destination, kind: .home)])
        defer { fixture.close() }
        fixture.provider.fails = true
        await fixture.submit("Prowadź do domu")
        #expect(fixture.provider.requestCount > 0)
        #expect(fixture.session.state.status != .navigating)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.replies.last?.contains("Nie udało się") == true)
        #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
    }

    @Test
    func failedDirectSavedReplacementKeepsTheActiveJourney() async throws {
        let destination = Destination(name: "Dom", coordinate: .init(latitude: 52.02, longitude: 21))
        let fixture = try SavedVoiceFixture(places: [SavedPlace(destination: destination, kind: .home)])
        defer { fixture.close() }
        let original = Destination(name: "Dotychczasowy cel", coordinate: .init(latitude: 52.01, longitude: 21))
        let route = SavedVoiceProvider.route(from: fixture.origin, to: original.coordinate)
        fixture.session.state.destination = original
        fixture.session.state.route = route
        fixture.session.state.routeOptions = [route]
        fixture.session.state.status = .navigating
        fixture.provider.fails = true

        await fixture.submit("Prowadź do domu")

        #expect(fixture.provider.requestCount > 0)
        #expect(fixture.session.state.destination?.id == original.id)
        #expect(fixture.session.state.route?.id == route.id)
        #expect(fixture.session.state.status == .navigating)
        #expect(!fixture.assistant.canConfirm)
        #expect(fixture.replies.last?.contains("Nie udało się") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func lateSavedRouteCannotStartAnExternallySelectedPreview() async throws {
        let home = Destination(name: "Dom", coordinate: .init(latitude: 52.02, longitude: 21))
        let fixture = try SavedVoiceFixture(places: [SavedPlace(destination: home, kind: .home)])
        defer { fixture.close() }
        fixture.provider.suspends = true
        fixture.assistant.submit("Prowadź do domu")
        let operation = try #require(fixture.assistant.task)
        await fixture.provider.waitUntilRequested()

        let replacement = Destination(name: "Ręcznie wybrany cel", coordinate: .init(latitude: 52.03, longitude: 21))
        fixture.session.selectDestination(replacement, applyConfiguredMode: false)
        fixture.session.state.route = SavedVoiceProvider.route(from: fixture.origin, to: replacement.coordinate)
        fixture.session.state.status = .routePreview
        fixture.provider.resume()
        await operation.value

        #expect(fixture.session.state.destination?.id == replacement.id)
        #expect(fixture.session.state.status == .routePreview)
        #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
    }

    @Test(.timeLimit(.minutes(1)))
    func closedConversationCannotAutoStartAfterItsOldPlanCompletes() async throws {
        let home = Destination(name: "Dom", coordinate: .init(latitude: 52.02, longitude: 21))
        let fixture = try SavedVoiceFixture(places: [SavedPlace(destination: home, kind: .home)])
        defer { fixture.close() }
        fixture.provider.suspends = true
        fixture.assistant.submit("Prowadź do domu")
        let operation = try #require(fixture.assistant.task)
        await fixture.provider.waitUntilRequested()
        #expect(fixture.assistant.isApplyingChange)
        fixture.assistant.close()
        fixture.provider.resume()
        await operation.value
        #expect(!fixture.assistant.isPresented)
        #expect(!fixture.assistant.isApplyingChange)
        #expect(fixture.session.state.status == .routePreview)
        #expect(fixture.replies.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func reopenedConversationLeavesWorkingAfterItsOldPlanCompletes() async throws {
        let home = Destination(name: "Dom", coordinate: .init(latitude: 52.02, longitude: 21))
        let fixture = try SavedVoiceFixture(places: [SavedPlace(destination: home, kind: .home)])
        defer { fixture.close() }
        fixture.provider.suspends = true
        fixture.assistant.submit("Prowadź do domu")
        let operation = try #require(fixture.assistant.task)
        await fixture.provider.waitUntilRequested()

        fixture.assistant.close()
        fixture.assistant.open()
        #expect(fixture.assistant.phase == .working)
        #expect(fixture.assistant.isApplyingChange)
        fixture.provider.resume()
        await operation.value

        #expect(fixture.assistant.isPresented)
        #expect(!fixture.assistant.isApplyingChange)
        #expect(fixture.assistant.phase == .idle)
        #expect(fixture.assistant.responseDismissalTask != nil)
        #expect(fixture.session.state.status == .routePreview)
        #expect(!fixture.replies.contains { $0.hasPrefix("Prowadzę do ") })
        #expect(!fixture.assistant.response.hasPrefix("Prowadzę do "))
    }
}

@MainActor
final class SavedVoiceFixture {
    let origin: Coordinate
    let session: NavigationSession
    let provider: SavedVoiceProvider
    let assistant: VoiceAssistant
    private let directory: URL
    private let previousDefaultMode: Any?
    private let previousOfflinePreference: Bool
    private let spoken: SavedVoiceReplies
    var replies: [String] { spoken.values }

    init(places: [SavedPlace], destinationResolver: VoiceDestinationResolver? = nil) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceSaved-\(UUID().uuidString)")
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(places).write(to: directory.appendingPathComponent("places.json"))
        let placeStore = PlaceStore(repository: LocalDataStore(directory: directory, removeLearningTrip: { _ in true }))
        previousDefaultMode = UserDefaults.standard.object(forKey: "defaultTransportMode")
        previousOfflinePreference = OfflineRoutingStore.shared.preferOffline
        // Public POI results retain their access metadata. Skip optional online
        // entrance lookup while the injected provider verifies actual routing.
        OfflineRoutingStore.shared.preferOffline = true
        UserDefaults.standard.set(TransportMode.walking.rawValue, forKey: "defaultTransportMode")
        let origin = Coordinate(latitude: 52, longitude: 21)
        self.origin = origin
        let provider = SavedVoiceProvider()
        self.provider = provider
        let session = NavigationSession(dependencies: .live(
            routeEndpoint: URL(string: "https://routing.invalid")!, trafficAPIKey: nil))
        self.session = session
        session.routeProvider = provider
        session.trafficProvider = nil
        session.plannedTripCalculation = true
        session.appIsForeground = false
        session.state.transportMode = .walking
        session.state.routingPreferences = RoutingPreferences()
        session.state.voiceEnabled = false
        session.voice.setEnabled(false)
        session.state.location = NavigationLocation(coordinate: origin, speed: 0, course: 0,
                                                    accuracy: 5, timestamp: .now)
        session.state.gpsQuality = .good
        session.state.routeOrigin = RoutePoint(Destination(name: "Początek", coordinate: origin), source: .search)
        let spoken = SavedVoiceReplies()
        self.spoken = spoken
        assistant = VoiceAssistant(navigationStore: NavigationStore(session: session), placeStore: placeStore,
            replySpeaker: { text, _ in spoken.values.append(text) }, interactionAvailable: { true },
            destinationResolver: destinationResolver)
    }

    func submit(_ text: String) async {
        assistant.submit(text)
        await assistant.task?.value
    }

    func close() {
        assistant.close()
        session.tripSession = nil
        session.stop()
        OfflineRoutingStore.shared.preferOffline = previousOfflinePreference
        if let previousDefaultMode { UserDefaults.standard.set(previousDefaultMode, forKey: "defaultTransportMode") }
        else { UserDefaults.standard.removeObject(forKey: "defaultTransportMode") }
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class SavedVoiceReplies {
    var values: [String] = []
}

@MainActor
final class SavedVoiceProvider: AdvancedRouteProvider {
    var requestCount = 0
    var fails = false
    var suspends = false
    private var suspended: CheckedContinuation<Void, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func waitUntilRequested() async {
        if suspended != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func resume() {
        suspended?.resume()
        suspended = nil
    }

    func calculateRoutes(from: Coordinate, to: Coordinate, mode: TransportMode) async throws -> [NavigationRoute] {
        requestCount += 1
        if suspends {
            await withCheckedContinuation {
                suspended = $0
                requested?.resume()
                requested = nil
            }
        }
        if fails { throw RoutingError.network }
        return [Self.route(from: from, to: to)]
    }

    func calculateRoutes(from: Coordinate, to: Coordinate, through: [Coordinate], mode: TransportMode,
                         preferences: RoutingPreferences, avoiding: [Coordinate]) async throws -> [NavigationRoute] {
        try await calculateRoutes(from: from, to: to, mode: mode)
    }

    func optimizedWaypointOrder(from: Coordinate, to: Coordinate, waypoints: [Destination], mode: TransportMode,
                                preferences: RoutingPreferences) async throws -> [Int] { [] }

    static func route(from: Coordinate, to: Coordinate) -> NavigationRoute {
        NavigationRoute(coordinates: [from, to], distance: from.distance(to: to),
                        expectedTravelTime: 900, maneuvers: [])
    }
}
#endif
