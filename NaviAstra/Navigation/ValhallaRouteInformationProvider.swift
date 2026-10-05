import Foundation
import CoreFoundation

actor ValhallaRouteInformationProvider {
    static let shared = ValhallaRouteInformationProvider()
    private var cache: [String: DetailedRouteInformation] = [:]

    func load(_ source: RouteInformationSource) async throws -> DetailedRouteInformation {
        guard source.endpoint.scheme == "https" else { throw RoutingError.invalidEndpoint }
        let key = source.endpoint.absoluteString + source.costing + source.shapes.joined(separator: "|")
        if let cached = cache[key] { return cached }
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
            cache[key] = details
        }
        return details
    }

    private func request(_ source: RouteInformationSource, shape: String, elevation: Bool) async throws -> Data {
        var request = URLRequest(url: source.endpoint.appendingPathComponent("trace_attributes"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let keys = ["edge.names", "edge.length", "edge.road_class", "edge.use", "edge.toll", "edge.unpaved",
                    "edge.tunnel", "edge.bridge", "edge.roundabout", "edge.drive_on_right", "edge.surface",
                    "edge.sign.exit_number", "edge.sign.exit_branch", "edge.sign.exit_toward", "edge.sign.exit_name",
                    "edge.mean_elevation", "edge.max_upward_grade", "edge.max_downward_grade", "edge.lane_count",
                    "edge.cycle_lane", "edge.bicycle_network", "edge.sac_scale", "edge.shoulder", "edge.sidewalk",
                    "edge.speed_limit", "edge.truck_speed", "edge.truck_route", "edge.country_crossing",
                    "edge.traffic_signal", "edge.hov_type", "node.time_zone", "admin.country_text", "admin.state_text"]
        var payload: [String: Any] = ["encoded_polyline": shape, "shape_match": "edge_walk",
                                    "costing": source.costing, "units": "kilometers",
                                    "filters": ["action": "include", "attributes": keys]]
        if elevation { payload["elevation_interval"] = 30 }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try await ValhallaRequestGate.shared.waitUntilAllowed(for: source.endpoint)
        try Task.checkCancellation()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RoutingError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw RoutingError.server(http.statusCode) }
        return data
    }

    nonisolated static func parse(_ data: Data, offset: Double = 0, firstID: Int = 0) throws -> DetailedRouteInformation {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["units"] as? String == "kilometers", let edges = root["edges"] as? [[String: Any]],
              !edges.isEmpty else { throw RoutingError.invalidResponse }
        var result = DetailedRouteInformation()
        var distance = offset
        for edge in edges {
            guard let length = number(edge["length"]), length >= 0, length <= 50000 else { throw RoutingError.invalidResponse }
            let meters = length * 1000
            result.sections.append(RouteRoadSection(id: firstID + result.sections.count,
                startMeters: distance, lengthMeters: meters, names: edge["names"] as? [String] ?? [],
                attributes: attributes(edge)))
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
        result.notices = (root["warnings"] as? [[String: Any]] ?? []).compactMap { $0["description"] as? String }
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
            if let value = number(edge[key]), value != 32768 { add(title, String(format: "%.0f %@", value, unit)) }
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
