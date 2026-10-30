import Foundation

enum DrivingLearningFailure: LocalizedError {
    case needsLocalMap, incompleteTrace, storage
    var errorDescription: String? {
        switch self {
        case .needsLocalMap: "Dopasowanie przejazdu wymaga lokalnej paczki dróg. Możesz ją pobrać w ustawieniach offline albo osobno zezwolić na dopasowanie śladu na serwerze."
        case .incompleteTrace: "Brakuje wystarczających, wiarygodnych fragmentów przejazdu lub pewnego dopasowania do dróg. Nie użyto tych danych do uczenia."
        case .storage: "Nie udało się zapisać preferencji tras na urządzeniu."
        }
    }
}

struct DrivingRouteMatcher {
    let endpoint: URL
    let settings: DrivingLearningSettings

    func match(_ points: [Coordinate], costing: String, recorded: Bool) async throws -> [LearnedRoadSegment] {
        guard points.count >= 2, points.allSatisfy(\.isValidValhallaCoordinate) else {
            throw DrivingLearningFailure.incompleteTrace
        }
        var result: [LearnedRoadSegment] = []
        // Small overlapping requests preserve the path without an unbounded payload.
        var start = 0
        while start < points.count - 1 {
            try Task.checkCancellation()
            let end = min(points.count, start + 500)
            let shape = Array(points[start..<end])
            let payload: [String: Any] = [
                "shape": shape.map { ["lat": $0.latitude, "lon": $0.longitude] },
                "costing": costing, "shape_match": "map_snap", "units": "kilometers",
                "trace_options": ["gps_accuracy": recorded ? 15 : 5, "search_radius": recorded ? 50 : 15],
                "filters": ["action": "include", "attributes": ["shape", "edge.id", "edge.way_id",
                    "edge.begin_osm_node_id", "edge.end_osm_node_id", "edge.begin_shape_index",
                    "edge.end_shape_index", "edge.length", "edge.names", "osm_changeset",
                    "matched.point", "matched.type", "matched.distance_from_trace_point",
                    "matched.begin_route_discontinuity", "matched.end_route_discontinuity"]]
            ]
            let data = try await request(payload)
            let part = try Self.decode(data, scope: endpoint.absoluteString, validateGPS: recorded)
            for segment in part {
                if result.last?.id == segment.id {
                    // A chunk boundary may split one directed edge.
                    let previous = result.removeLast()
                    result.append(LearnedRoadSegment(id: segment.id,
                        coordinates: previous.coordinates + segment.coordinates,
                        length: previous.length + segment.length, names: segment.names))
                } else { result.append(segment) }
            }
            start = end - 1
        }
        return result
    }

    private func request(_ payload: [String: Any]) async throws -> Data {
        #if os(iOS)
        if let pack = OfflineRoutingStore.shared.activePack {
            do {
                return try await OfflineRoutingEngine.shared.traceAttributes(
                    request: JSONSerialization.data(withJSONObject: payload), pack: pack)
            } catch {
                try Task.checkCancellation()
                guard settings.allowRemoteMatching else { throw error }
            }
        }
        #endif
        guard settings.allowRemoteMatching else { throw DrivingLearningFailure.needsLocalMap }
        return try await ValhallaServices(endpoint: endpoint).request("trace_attributes", payload: payload)
    }

    nonisolated static func decode(_ data: Data, scope: String, validateGPS: Bool) throws -> [LearnedRoadSegment] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["units"] as? String == "kilometers", let encoded = root["shape"] as? String,
              let edges = root["edges"] as? [[String: Any]], !edges.isEmpty else {
            throw DrivingLearningFailure.incompleteTrace
        }
        let points = root["matched_points"] as? [[String: Any]] ?? []
        if validateGPS {
            if let confidence = (root["confidence_score"] as? NSNumber)?.doubleValue,
               !confidence.isFinite || confidence < 0.8 { throw DrivingLearningFailure.incompleteTrace }
            guard points.count >= 2, points.allSatisfy({
                $0["type"] as? String != "unmatched"
                    && $0["begin_route_discontinuity"] as? Bool != true
                    && $0["end_route_discontinuity"] as? Bool != true
                    && (($0["distance_from_trace_point"] as? NSNumber)?.doubleValue ?? .infinity) <= 50
            }) else { throw DrivingLearningFailure.incompleteTrace }
        }
        let shape = Polyline6.decode(encoded)
        guard shape.count >= 2, shape.allSatisfy(\.isValidValhallaCoordinate) else {
            throw DrivingLearningFailure.incompleteTrace
        }
        let dataset = (root["osm_changeset"] as? NSNumber)?.stringValue ?? "unknown"
        return try edges.compactMap { edge -> LearnedRoadSegment? in
            guard let begin = edge["begin_shape_index"] as? Int,
                  let end = edge["end_shape_index"] as? Int,
                  begin >= 0, end >= begin, end < shape.count,
                  let length = (edge["length"] as? NSNumber)?.doubleValue,
                  length.isFinite, (0...200).contains(length) else { throw DrivingLearningFailure.incompleteTrace }
            guard end > begin, length > 0 else { return nil }
            let coordinates = Array(shape[begin...end])
            let id: String
            if let way = edge["way_id"] as? NSNumber,
               let from = edge["begin_osm_node_id"] as? NSNumber,
               let to = edge["end_osm_node_id"] as? NSNumber,
               way.uint64Value > 0, from.uint64Value > 0, to.uint64Value > 0 {
                id = "osm:\(way.stringValue):\(from.stringValue):\(to.stringValue)"
            } else if let graph = edge["id"] as? NSNumber {
                // Add geometry to avoid sharing stale graph identifiers across datasets.
                let first = coordinates[0], last = coordinates[coordinates.count - 1]
                id = "graph:\(scope):\(dataset):\(graph.stringValue):\(Int(first.latitude * 100_000)):\(Int(first.longitude * 100_000)):\(Int(last.latitude * 100_000)):\(Int(last.longitude * 100_000))"
            } else { throw DrivingLearningFailure.incompleteTrace }
            return LearnedRoadSegment(id: id, coordinates: Self.compactGeometry(coordinates), length: length * 1_000,
                                      names: edge["names"] as? [String] ?? [])
        }
    }

    nonisolated private static func compactGeometry(_ points: [Coordinate]) -> [Coordinate] {
        guard points.count > 64 else { return points }
        return (0..<64).map { points[Int(Double($0) * Double(points.count - 1) / 63)] }
    }
}
