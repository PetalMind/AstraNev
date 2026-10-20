import Foundation
import CoreFoundation

actor ValhallaRouteInformationProvider {
    static let shared = ValhallaRouteInformationProvider()
    private var cache: [String: (date: Date, details: DetailedRouteInformation)] = [:]

    func load(_ source: RouteInformationSource) async throws -> DetailedRouteInformation {
        guard source.endpoint.scheme == "https" else { throw RoutingError.invalidEndpoint }
        let key = source.endpoint.absoluteString + source.costing + String(describing: source.planningTime) + source.shapes.joined(separator: "|")
        if let cached = cache[key], Date().timeIntervalSince(cached.date) < 60 { return cached.details }
        var details = DetailedRouteInformation(totalLegs: source.shapes.count)
        var offset = 0.0
        for shape in source.shapes {
            try Task.checkCancellation()
            let coordinates = Polyline6.decode(shape)
            let legLength = zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            do {
                let data: Data
                do {
                    data = try await request(source, shape: shape, elevation: true)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    // Older servers may reject elevation; keep road attribution available.
                    data = try await request(source, shape: shape, elevation: false)
                }
                let leg = try Self.parse(data, offset: offset, firstID: details.sections.count)
                details.sections += leg.sections
                if !details.elevations.isEmpty, let last = details.elevations.last,
                   let first = leg.elevations.first, abs(last.distanceMeters - first.distanceMeters) < 0.01 {
                    details.elevations.removeLast()
                }
                if leg.elevations.isEmpty {
                    details.elevations.append(RouteElevationSample(distanceMeters: offset, heightMeters: nil))
                } else {
                    details.elevations += leg.elevations
                }
                details.countries += leg.countries
                details.regions += leg.regions
                details.notices += leg.notices
                details.completedLegs += 1
            } catch {
                if Task.isCancelled { throw CancellationError() }
                details.notices.append("Nie udało się pobrać szczegółów części trasy. Spróbuj ponownie.")
                // A gap must not be joined into a false elevation gain.
                details.elevations.append(RouteElevationSample(distanceMeters: offset, heightMeters: nil))
            }
            offset += legLength
        }
        details.countries = Array(Set(details.countries)).sorted()
        details.regions = Array(Set(details.regions)).sorted()
        details.notices = Array(Set(details.notices)).sorted()
        if details.completedLegs == details.totalLegs {
            if cache.count >= 8 { cache.removeAll() }
            cache[key] = (Date(), details)
        }
        return details
    }

    private func request(_ source: RouteInformationSource, shape: String, elevation: Bool) async throws -> Data {
        var request = URLRequest(url: source.endpoint.appendingPathComponent("trace_attributes"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("NaviAstra", forHTTPHeaderField: "X-Client-Id")
        let keys = ["edge.names", "edge.length", "edge.road_class", "edge.use", "edge.toll", "edge.unpaved",
                    "edge.tunnel", "edge.bridge", "edge.roundabout", "edge.drive_on_right", "edge.surface",
                    "edge.sign.exit_number", "edge.sign.exit_branch", "edge.sign.exit_toward", "edge.sign.exit_name",
                    "edge.mean_elevation", "edge.max_upward_grade", "edge.max_downward_grade", "edge.lane_count",
                    "edge.cycle_lane", "edge.bicycle_network", "edge.sac_scale", "edge.shoulder", "edge.sidewalk",
                    "edge.speed_limit", "edge.truck_speed", "edge.truck_route", "edge.country_crossing",
                    "edge.traffic_signal", "edge.hov_type", "node.time_zone", "admin.country_text", "admin.state_text",
                    "edge.way_id", "edge.id", "edge.traversability", "edge.begin_heading", "edge.end_heading",
                    "edge.begin_shape_index", "edge.end_shape_index", "edge.speed", "edge.speeds_non_faded",
                    "edge.begin_osm_node_id", "edge.end_osm_node_id", "node.elapsed_time", "node.type",
                    "node.intersecting_edge.begin_heading", "node.intersecting_edge.driveability",
                    "node.intersecting_edge.cyclability", "node.intersecting_edge.walkability",
                    "node.intersecting_edge.road_class", "node.intersecting_edge.lane_count",
                    "shape_attributes.time", "shape_attributes.length", "shape_attributes.speed",
                    "shape_attributes.closure", "shape_attributes.congestion", "osm_changeset"]
        var payload: [String: Any] = ["encoded_polyline": shape, "shape_match": "edge_walk",
                                    "costing": source.costing, "units": "kilometers",
                                    "filters": ["action": "include", "attributes": keys]]
        if elevation { payload["elevation_interval"] = 30 }
        payload["date_time"] = (source.planningTime ?? ValhallaPlanningTime(type: 0)).payload
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try await ValhallaRequestGate.shared.waitUntilAllowed(for: source.endpoint)
        try Task.checkCancellation()
        let (data, response) = try await URLSession.shared.data(for: request)
        try ValhallaServices.validate(data: data, response: response)
        return data
    }

    nonisolated static func parse(_ data: Data, offset: Double = 0, firstID: Int = 0) throws -> DetailedRouteInformation {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["units"] as? String == "kilometers", let edges = root["edges"] as? [[String: Any]],
              !edges.isEmpty else { throw RoutingError.invalidResponse }
        var result = DetailedRouteInformation()
        var distance = offset
        let shapeAttributes = root["shape_attributes"] as? [String: Any]
        for edge in edges {
            guard let length = number(edge["length"]), length >= 0, length <= 50000 else { throw RoutingError.invalidResponse }
            let meters = length * 1000
            result.sections.append(RouteRoadSection(id: firstID + result.sections.count,
                startMeters: distance, lengthMeters: meters, names: edge["names"] as? [String] ?? [],
                attributes: attributes(edge) + shapeItems(edge, shape: shapeAttributes)))
            distance += meters
        }
        if let samples = root["elevation"] as? [Any], let interval = number(root["elevation_interval"]), interval > 0 {
            for (index, sample) in samples.enumerated() {
                let height = number(sample).flatMap { $0 == 32768 || !(-500...9000).contains($0) ? nil : $0 }
                result.elevations.append(RouteElevationSample(
                    distanceMeters: min(distance, offset + Double(index) * interval), heightMeters: height))
            }
        }
        result.countries = (root["admins"] as? [[String: Any]] ?? []).compactMap { $0["country_text"] as? String }
        result.regions = (root["admins"] as? [[String: Any]] ?? []).compactMap { $0["state_text"] as? String }
        if let changeset = root["osm_changeset"] as? NSNumber {
            result.notices.append("Identyfikator zbioru danych OSM: " + changeset.stringValue)
        }
        result.notices += (root["warnings"] as? [[String: Any]] ?? []).compactMap { $0["description"] as? String }
        return result
    }


    nonisolated private static func shapeItems(_ edge: [String: Any], shape: [String: Any]?) -> [RouteInformationItem] {
        guard let shape, let begin = number(edge["begin_shape_index"]), let end = number(edge["end_shape_index"]),
              begin >= 0, end > begin, end < 1_000_000 else { return [] }
        let start = Int(begin), finish = Int(end)
        var result: [RouteInformationItem] = []
        if let speeds = shape["speed"] as? [Double], speeds.count >= finish {
            let values = speeds[start..<finish].filter { $0.isFinite && $0 >= 0 }
            if let low = values.min(), let high = values.max() {
                result.append(RouteInformationItem(title: "Prędkości fragmentów wg modelu", value: "\(Int(low.rounded()))–\(Int(high.rounded())) km/h"))
            }
        }
        if let times = shape["time"] as? [Double], times.count >= finish {
            let values = times[start..<finish]
            if values.allSatisfy({ $0.isFinite && $0 >= 0 }) {
                result.append(RouteInformationItem(title: "Czas fragmentu wg modelu", value: "\(Int(values.reduce(0, +).rounded())) s"))
            }
        }
        if let closures = (shape["closure"] ?? shape["closures"]) as? [[String: Any]], closures.contains(where: {
            guard let from = number($0["begin_shape_index"]), let to = number($0["end_shape_index"]) else { return false }
            return from < end && to > begin
        }) { result.append(RouteInformationItem(title: "Zamknięcie zgłoszone przez serwer", value: "Tak")) }
        let flows = edge["speeds_non_faded"] as? [String: Any]
        // Servers may emit an all-zero congestion array without any traffic data.
        if flows?["current_flow"] != nil, let congestions = shape["congestion"] as? [Double], congestions.count >= finish {
            let values = congestions[start..<finish].filter { $0.isFinite && $0 >= 0 && $0 <= 100 }
            if let maxValue = values.max() {
                result.append(RouteInformationItem(title: "Natężenie wg serwera (0–100)",
                                                   value: String(format: "%.0f", locale: PolishRegionalFormat.locale, maxValue)))
            }
        }
        return result
    }

    nonisolated private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    nonisolated private static func attributes(_ edge: [String: Any]) -> [RouteInformationItem] {
        var values: [RouteInformationItem] = []
        func add(_ title: String, _ value: String?) {
            if let value, !value.isEmpty { values.append(RouteInformationItem(title: title, value: value)) }
        }
        func translated(_ key: String, _ options: [String: String]) -> String? {
            guard let value = edge[key] as? String else { return nil }
            return options[value] // Unknown future enum values aren't invented as user facts.
        }
        if let wayID = edge["way_id"] as? NSNumber { add("Droga OSM", wayID.stringValue) }
        if let edgeID = edge["id"] as? NSNumber { add("Odcinek grafu", edgeID.stringValue) }
        add("Przejezdność", translated("traversability", ["forward":"Zgodnie z kierunkiem odcinka", "backward":"Przeciwnie do kierunku odcinka", "both":"W obu kierunkach"]))
        for (key, title) in [("begin_heading", "Kierunek początku"), ("end_heading", "Kierunek końca")] {
            if let value = number(edge[key]), (0..<360).contains(value) { add(title, "\(Int(value.rounded()))°") }
        }
        if let speed = number(edge["speed"]), speed > 0 { add("Prędkość modelu routingu", "\(Int(speed.rounded())) km/h") }
        if let flows = edge["speeds_non_faded"] as? [String: Any] {
            for (key, title) in [("current_flow", "Prędkość bieżącego ruchu"), ("predicted_flow", "Prędkość przewidywana"),
                                 ("free_flow", "Prędkość swobodnego ruchu")] {
                if let speed = number(flows[key]), speed >= 0 { add(title, "\(Int(speed.rounded())) km/h") }
            }
        }
        if let node = edge["end_node"] as? [String: Any] {
            if let elapsed = number(node["elapsed_time"]) { add("Czas od startu wg modelu", "\(Int(elapsed.rounded())) s") }
            if let nodeID = node["node_id"] as? NSNumber { add("Węzeł OSM na końcu", nodeID.stringValue) }
            if let intersections = node["intersecting_edges"] as? [[String: Any]], !intersections.isEmpty {
                add("Odnogi skrzyżowania", "\(intersections.count)")
                for (index, intersection) in intersections.enumerated() {
                    var parts: [String] = []
                    if let heading = number(intersection["begin_heading"]) { parts.append("\(Int(heading.rounded()))°") }
                    for (key, label) in [("driveability","auto"),("cyclability","rower"),("walkability","pieszo")] {
                        if let value = intersection[key] as? String,
                           let direction = ["forward":"w kierunku odnogi", "backward":"z kierunku odnogi", "both":"oba kierunki", "none":"brak dostępu"][value] {
                            parts.append("\(label): \(direction)")
                        }
                    }
                    add("Odnoga \(index + 1)", parts.joined(separator: " · "))
                }
            }
        }
        add("Nawierzchnia", translated("surface", ["paved_smooth":"Utwardzona gładka", "paved":"Utwardzona",
            "paved_rough":"Utwardzona nierówna", "compacted":"Ubita", "dirt":"Gruntowa", "gravel":"Żwirowa",
            "path":"Ścieżka", "impassable":"Nieprzejezdna"]))
        add("Klasa drogi", translated("road_class", ["motorway":"Autostrada", "trunk":"Droga główna o dużej przepustowości",
            "primary":"Droga główna", "secondary":"Droga drugorzędna", "tertiary":"Droga lokalna",
            "unclassified":"Droga bez klasy", "residential":"Ulica osiedlowa", "service_other":"Droga dojazdowa"]))
        add("Rodzaj odcinka", translated("use", ["road":"Droga", "ramp":"Łącznica", "turn_channel":"Pas skrętu",
            "track":"Droga polna lub leśna", "driveway":"Dojazd", "alley":"Alejka", "parking_aisle":"Alejka parkingowa",
            "emergency_access":"Dojazd awaryjny", "drive_through":"Przejazd usługowy", "culdesac":"Ślepa ulica",
            "cycleway":"Droga rowerowa", "mountain_bike":"Trasa MTB", "sidewalk":"Chodnik", "footway":"Droga piesza",
            "steps":"Schody", "ferry":"Prom", "rail-ferry":"Prom kolejowy", "other":"Inny odcinek"]))
        if let speed = number(edge["speed_limit"]), speed > 0, speed < 200 { add("Limit prędkości", "\(Int(speed)) km/h") }
        if let lanes = number(edge["lane_count"]), lanes > 0, lanes <= 32 { add("Liczba pasów", "\(Int(lanes))") }
        add("Chodnik", translated("sidewalk", ["left":"Po lewej", "right":"Po prawej", "both":"Po obu stronach", "none":"Brak w danych"]))
        add("Pas rowerowy", translated("cycle_lane", ["none":"Brak w danych", "shared":"Współdzielony", "dedicated":"Wydzielony", "separated":"Odseparowany"]))
        if number(edge["bicycle_network"]).map({ $0 > 0 }) == true || edge["bicycle_network"] as? Bool == true {
            add("Sieć rowerowa", "Odcinek sieci rowerowej")
        }
        if let scale = number(edge["sac_scale"]), (1...6).contains(scale), let label = [1:"Piesza",2:"Górska",3:"Wymagająca górska",4:"Alpejska",5:"Wymagająca alpejska",6:"Trudna alpejska"][Int(scale)] { add("Trudność szlaku", label) }
        for (key, title) in [("toll","Opłaty"),("unpaved","Nawierzchnia nieutwardzona lub nierówna"),
                             ("tunnel","Tunel"),("bridge","Most"),("roundabout","Rondo"),
                             ("shoulder","Pobocze"),("country_crossing","Przekroczenie granicy"),
                             ("traffic_signal","Sygnalizacja świetlna"),("truck_route","Trasa dla ciężarówek")] {
            if edge[key] as? Bool == true { add(title, "Tak") }
        }
        if let right = edge["drive_on_right"] as? Bool { add("Strona ruchu", right ? "Prawostronny" : "Lewostronny") }
        for (key, title, unit) in [("mean_elevation","Średnia wysokość","m n.p.m."),
                                  ("max_upward_grade","Maksymalny podjazd","%"),
                                  ("max_downward_grade","Maksymalny zjazd","%")] {
            if let value = number(edge[key]), value != 32768 {
                add(title, String(format: "%.0f %@", locale: PolishRegionalFormat.locale, value, unit))
            }
        }
        if let speed = number(edge["truck_speed"]), speed > 0, speed < 300 { add("Prędkość routingu ciężarówek", "\(Int(speed)) km/h") }
        add("Pas HOV", translated("hov_type", ["hov2":"Min. 2 osoby", "hov3":"Min. 3 osoby"]))
        if let node = edge["end_node"] as? [String: Any] { add("Strefa czasowa", node["time_zone"] as? String) }
        if let sign = edge["sign"] as? [String: Any] {
            for (key, title) in [("exit_number","Numery zjazdów"),("exit_branch","Drogi na zjeździe"),
                                 ("exit_toward","Kierunki na drogowskazie"),("exit_name","Nazwa węzła")] {
                add(title, (sign[key] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " · "))
            }
        }
        return values
    }
}
