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

    static func describe(_ options: [NavigationRoute], mode: TransportMode, at date: Date = Date()) -> [UUID: Description] {
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
        func award(_ trait: Trait, values: [Double?], minimumSpread: Double, explanation: String,
                   allowsExcludedCandidates: Bool = false) {
            guard values.count == routes.count else { return }
            let present = values.compactMap { $0 }
            let known = present.filter { $0.isFinite && $0 >= 0 }
            let comparable = allowsExcludedCandidates
                ? present.count == routes.count && present.allSatisfy { !$0.isNaN && $0 >= 0 }
                : known.count == routes.count
            guard comparable, let best = known.min(), let worst = present.max(),
                  worst - best >= minimumSpread else { return }
            for index in routes.indices where abs((values[index] ?? .infinity) - best) <= 0.000_001 {
                result[routes[index].id]?.traits.append(trait)
                if result[routes[index].id]?.traits.count == 1 {
                    result[routes[index].id]?.explanation = explanation
                }
            }
        }

        award(.fastest, values: routes.map { $0.previewTravelTime(at: date) }, minimumSpread: 1,
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
                      routes[index].previewTravelTime(at: date).isFinite, routes[index].previewTravelTime(at: date) >= 0 else { return nil }
                return Double(journey.transferCount) * 720 + walk * 1.9
                    + journey.waitingDuration * 0.15 + routes[index].previewTravelTime(at: date) * 0.45
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
                return RouteScore(travelTime: route.previewTravelTime(at: date), distance: route.distance,
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
                          minimumSpread: 1,
                          explanation: surfaceKnown
                            ? "Łatwiejsze manewry i znana nawierzchnia przy ograniczonym wydłużeniu podróży."
                            : "Łatwiejsze manewry przy ograniczonym wydłużeniu podróży. Brak pełnych danych o nawierzchni.",
                          allowsExcludedCandidates: true)
                }
                award(.balanced,
                      values: RouteScoringEngine.rankingValues(scores, preference: .balanced).map { Optional($0) },
                      minimumSpread: 1,
                      explanation: "Bilans czasu, dystansu i manewrów: do 15% i najwyżej 5 min dłużej od najszybszej trasy.",
                      allowsExcludedCandidates: true)
            }
        }

        // Explain convenience first when a route also happens to be fastest/shortest.
        let displayOrder: [Trait] = [.fastest, .comfortable, .fewestTransfers, .leastWalking,
                                     .shortest, .earliestArrival, .balanced]
        let fastest = routes.filter { $0.previewTravelTime(at: date).isFinite && $0.previewTravelTime(at: date) >= 0 }
            .min { $0.previewTravelTime(at: date) == $1.previewTravelTime(at: date)
                ? $0.distance < $1.distance : $0.previewTravelTime(at: date) < $1.previewTravelTime(at: date) }
        for route in routes {
            guard var description = result[route.id] else { continue }
            description.traits = displayOrder.filter(description.traits.contains)
            if description.traits.contains(.comfortable) {
                description.explanation = mode == .car
                    ? "Profil wygodny: do 25% i najwyżej 10 min dłużej; do 30% i najwyżej 10 km dalej od najszybszej trasy. Nawierzchnia jest porównywana przy pełnych danych."
                    : "Najlepszy bilans liczby przesiadek, dojścia pieszo, oczekiwania i czasu podróży."
            } else if description.traits.contains(.leastWalking) || description.traits.contains(.fewestTransfers) {
                description.explanation = "Porównanie obejmuje czas podróży, przesiadki i planowany czas dojścia pieszo."
            }
            if mode == .car, let fastest {
                let comparison = comparison(route, against: fastest, at: date)
                if !comparison.isEmpty { description.explanation += " " + comparison }
            }
            result[route.id] = description
        }
        return result
    }

    private static func comparison(_ route: NavigationRoute, against reference: NavigationRoute, at date: Date) -> String {
        guard route.id != reference.id else { return "Ten wariant wyznacza najkrótszy szacowany czas podróży." }
        var differences: [String] = []
        let extraTime = route.previewTravelTime(at: date) - reference.previewTravelTime(at: date)
        if extraTime.isFinite, extraTime >= 1 {
            let formatter = DateComponentsFormatter()
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "pl_PL")
            formatter.calendar = calendar
            formatter.allowedUnits = extraTime < 60 ? [.second] : [.hour, .minute]
            formatter.unitsStyle = .abbreviated
            if let text = formatter.string(from: extraTime) { differences.append("dłużej o " + text) }
        } else if extraTime.isFinite {
            differences.append("taki sam szacowany czas")
        }
        let extraDistance = route.distance - reference.distance
        if extraDistance.isFinite, abs(extraDistance) >= 100 {
            let kilometres = (abs(extraDistance) / 1_000).formatted(
                .number.locale(Locale(identifier: "pl_PL")).precision(.fractionLength(0...1)))
            differences.append((extraDistance > 0 ? "dalej o " : "krócej o ") + kilometres + " km")
        }
        if !route.maneuvers.isEmpty, !reference.maneuvers.isEmpty {
            let turns = route.maneuvers.filter { RouteScoringEngine.maneuverCost($0.kind) > 0 }.count
            let referenceTurns = reference.maneuvers.filter { RouteScoringEngine.maneuverCost($0.kind) > 0 }.count
            if turns != referenceTurns {
                differences.append("manewry kierunkowe: \(turns) zamiast \(referenceTurns)")
            }
        }
        return differences.isEmpty ? "" : "W porównaniu z najszybszym wariantem: " + differences.joined(separator: ", ") + "."
    }
}
#endif
