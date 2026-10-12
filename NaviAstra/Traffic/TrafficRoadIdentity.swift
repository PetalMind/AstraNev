import Foundation

/// Only use signed geometry when a provider explicitly defines its direction.
/// Neither an OSM way direction nor TMC positive/negative is a compass bearing.
nonisolated enum TrafficGeometryDirection: Sendable {
    case unknown, forward, backward
}

nonisolated enum TrafficRoadIdentity {
    static func references(_ values: [String]) -> Set<String> {
        Set(values.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ";,/")) }
            .compactMap { value in
                var normalized = value.uppercased().filter { !$0.isWhitespace }
                for prefix in ["DK", "DW"] where normalized.hasPrefix(prefix) {
                    normalized.removeFirst(prefix.count)
                    break
                }
                guard normalized.range(of: "^(?:[ASE])?[0-9]{1,4}$", options: .regularExpression) != nil else { return nil }
                return normalized
            })
    }

    static func accepts(_ roadNumbers: [String], on route: NavigationRoute,
                        at projection: RouteProjection) -> Bool {
        let reported = references(roadNumbers)
        guard !reported.isEmpty,
              let maneuver = route.maneuvers.filter({ $0.shapeIndex <= projection.segment })
                .max(by: { $0.shapeIndex < $1.shapeIndex }) else { return true }
        let routed = references(maneuver.streetNames)
        // E30 and A2 can name the same road. Compare only references in a shared namespace.
        if routed.isEmpty || !reported.isDisjoint(with: routed) { return true }
        func family(_ reference: String) -> Character { reference.first!.isNumber ? "#" : reference.first! }
        let sharedFamilies = Set(reported.map(family)).intersection(Set(routed.map(family)))
        return sharedFamilies.isEmpty
    }
}
