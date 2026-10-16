#if os(iOS)
import Foundation

/// Presentation only: compares the currently available options without changing their order or ETA.
enum RouteVariantDescriptions {
    enum Trait: String, Identifiable {
        case fastest, shortest, comfortable, balanced, leastWalking, fewestTransfers, earliestArrival

        var id: Self { self }

        var title: String {
            switch self {
            case .fastest: "Najszybszy"
            case .shortest: "Najkrótszy"
            case .comfortable: "Najwygodniejszy"
            case .balanced: "Zrównoważony"
            case .leastWalking: "Najmniej pieszo"
            case .fewestTransfers: "Najmniej przesiadek"
            case .earliestArrival: "Najwcześniej u celu"
            }
        }
    }

    struct Description {
        var traits: [Trait] = []
        var explanation: String = "Alternatywny plan podróży wśród dostępnych wariantów."

        var title: String {
            traits.isEmpty ? "Wariant trasy" : traits.map(\.title).joined(separator: " · ")
        }

        var compactTitle: String {
            traits.isEmpty ? title : traits.prefix(2).map(\.title).joined(separator: " · ")
        }
    }

    static func describe(_ options: [NavigationRoute], mode: TransportMode) -> [UUID: Description] {
        var seen = Set<UUID>()
        let routes = options.filter { seen.insert($0.id).inserted }
        var result = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, Description()) })
        guard routes.count > 1 else {
            if let route = routes.first {
                result[route.id] = Description(explanation: "Dostępny wariant trasy. Brak innych tras do porównania.")
            }
            return result
        }

        // Require comparable data for every option. Ties receive the same description;
        // neither provider order nor the selected route breaks a tie.
        func award(_ trait: Trait, values: [Double?], minimumSpread: Double, explanation: String) {
            guard values.count == routes.count else { return }
            let known = values.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
            guard known.count == routes.count, let best = known.min(), let worst = known.max(),
                  worst - best >= minimumSpread else { return }
            for index in routes.indices where abs(known[index] - best) <= 0.000_001 {
                result[routes[index].id]?.traits.append(trait)
                if result[routes[index].id]?.traits.count == 1 {
                    result[routes[index].id]?.explanation = explanation
                }
            }
        }

        award(.fastest, values: routes.map { $0.expectedTravelTime }, minimumSpread: 1,
              explanation: routes.contains(where: { !$0.chargingStops.isEmpty })
                ? "Najkrótszy szacowany czas podróży wśród dostępnych wariantów, z uwzględnieniem zaplanowanego ładowania."
                : "Najkrótszy szacowany czas podróży wśród dostępnych wariantów.")
        award(.shortest, values: routes.map { $0.distance }, minimumSpread: 1,
              explanation: "Najmniejszy dystans wśród dostępnych wariantów.")

        if mode == .transit {
            award(.fewestTransfers, values: routes.map { $0.journey.map { Double($0.transferCount) } },
                  minimumSpread: 1, explanation: "Najmniejsza liczba przesiadek wśród dostępnych połączeń.")
            let walking: [Double?] = routes.map { route in
                guard let journey = route.journey, !journey.legs.isEmpty else { return nil }
                let durations = journey.legs.filter { $0.mode.uppercased() == "WALK" }.map(\.plannedWalkingDuration)
                guard durations.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
                return durations.reduce(0, +)
            }
            award(.leastWalking, values: walking, minimumSpread: 60,
                  explanation: "Najkrótszy planowany czas dojścia pieszo wśród dostępnych połączeń.")
            award(.earliestArrival, values: routes.map { $0.journey?.arrival.timeIntervalSince1970 },
                  minimumSpread: 60, explanation: "Najwcześniejszy planowany przyjazd, z uwzględnieniem godzin odjazdu.")
            let comfort: [Double?] = routes.indices.map { index in
                guard let journey = routes[index].journey, let walk = walking[index],
                      journey.transferCount >= 0,
                      journey.waitingDuration.isFinite, journey.waitingDuration >= 0,
                      routes[index].expectedTravelTime.isFinite, routes[index].expectedTravelTime >= 0 else { return nil }
                return Double(journey.transferCount) * 720 + walk * 1.9
                    + journey.waitingDuration * 0.15 + routes[index].expectedTravelTime * 0.45
            }
            award(.comfortable, values: comfort, minimumSpread: 1,
                  explanation: "Najlepszy bilans liczby przesiadek, dojścia pieszo, oczekiwania i czasu podróży.")
        } else if mode == .car {
            // Use the existing ranking weights with the same times shown on the cards.
            // No geometry reconstruction, selected-route traffic or personalized ordering is needed.
            let scores = routes.map { route in
                let surfaceKnown = !route.maneuvers.isEmpty && route.maneuvers.allSatisfy {
                    guard let rough = $0.information?.rough else { return false }
                    return !rough || ($0.information?.distanceMeters.map { $0.isFinite && $0 >= 0 } ?? false)
                }
                let surfaceCost = surfaceKnown ? route.maneuvers.reduce(0.0) {
                    $0 + ($1.information?.rough == true ? ($1.information?.distanceMeters ?? 0) / 1_000 * 30 : 0)
                } : nil
                return RouteScore(travelTime: route.expectedTravelTime, distance: route.distance,
                    trafficDelay: nil,
                    maneuverCost: route.maneuvers.reduce(0) { $0 + RouteScoringEngine.maneuverCost($1.kind) },
                    roadQualityCost: surfaceCost, reliabilityCost: nil, tollCost: nil,
                    hasManeuverData: !route.maneuvers.isEmpty)
            }
            if scores.allSatisfy({ $0.hasManeuverData && $0.travelTime.isFinite && $0.travelTime >= 0
                && $0.distance.isFinite && $0.distance >= 0 }) {
                let surfaceKnown = scores.allSatisfy { $0.roadQualityCost != nil }
                let comfortCosts = scores.map { $0.maneuverCost + (surfaceKnown ? $0.roadQualityCost ?? 0 : 0) }
                if let best = comfortCosts.min(), let worst = comfortCosts.max(), worst > best {
                    award(.comfortable,
                          values: RouteScoringEngine.rankingValues(scores, preference: .comfortable).map { Optional($0) },
                          minimumSpread: 0.000_001,
                          explanation: surfaceKnown
                            ? "Najlepszy bilans łatwości manewrów, nawierzchni, czasu i dystansu według profilu wygodnego."
                            : "Najlepszy bilans łatwości manewrów, czasu i dystansu według profilu wygodnego. Brak pełnych danych o nawierzchni.")
                }
                award(.balanced,
                      values: RouteScoringEngine.rankingValues(scores, preference: .balanced).map { Optional($0) },
                      minimumSpread: 0.000_001,
                      explanation: "Najlepszy bilans czasu, dystansu i łatwości przejazdu według profilu zrównoważonego.")
            }
        }

        // Explain convenience first when a route also happens to be fastest/shortest.
        let displayOrder: [Trait] = [.fastest, .comfortable, .fewestTransfers, .leastWalking,
                                     .shortest, .earliestArrival, .balanced]
        for route in routes {
            guard var description = result[route.id] else { continue }
            description.traits = displayOrder.filter(description.traits.contains)
            if description.traits.contains(.comfortable) {
                description.explanation = mode == .car
                    ? "Ocena profilu wygodnego uwzględnia łatwość manewrów, czas i dystans. Nawierzchnia jest porównywana tylko przy pełnych danych dla wszystkich wariantów."
                    : "Najlepszy bilans liczby przesiadek, dojścia pieszo, oczekiwania i czasu podróży."
            } else if description.traits.contains(.leastWalking) || description.traits.contains(.fewestTransfers) {
                description.explanation = "Porównanie obejmuje czas podróży, przesiadki i planowany czas dojścia pieszo."
            }
            result[route.id] = description
        }
        return result
    }
}
#endif
