import Foundation
import CryptoKit

nonisolated enum RoadIncidentSource: String, Codable, Sendable, CaseIterable, Hashable {
    case tomTom, gddkia, local, community
    var title: String {
        switch self {
        case .tomTom: "TomTom"
        case .gddkia: "GDDKiA"
        case .local: "Zgłoszenie lokalne · niepotwierdzone"
        case .community: "Zgłoszenie wspólne · niepotwierdzone"
        }
    }
    var url: URL? {
        switch self {
        case .tomTom: URL(string: "https://www.tomtom.com/traffic-index/")
        case .gddkia: URL(string: "https://www.gov.pl/web/gddkia/dane-xml")
        case .local, .community: nil
        }
    }
}

/// The official national-road bulletin is a source of notices, not measured speed.
actor GDDKiARoadIncidents {
    static let shared = GDDKiARoadIncidents()
    private var cached: (incidents: [TrafficIncident], fetchedAt: Date, generatedAt: Date)?
    private var pending: Task<([TrafficIncident], Date), Error>?
    private var retryAfter = Date.distantPast
    static let endpoint = URL(string: "https://www.archiwum.gddkia.gov.pl/dane/zima_html/utrdane.xml")!

    func incidents(in boxes: [TrafficBoundingBox]) async throws -> [TrafficIncident] {
        guard boxes.contains(where: { $0.maxLatitude >= 48 && $0.minLatitude <= 56 && $0.maxLongitude >= 13 && $0.minLongitude <= 25 }) else { return [] }
        let now = Date()
        if let cached, now.timeIntervalSince(cached.fetchedAt) < 300,
           now.timeIntervalSince(cached.generatedAt) < 86_400 {
            return filtered(cached.incidents, boxes: boxes, observedAt: cached.fetchedAt, now: now)
        }
        guard now >= retryAfter else { throw TrafficError.sourceUnavailable("GDDKiA") }
        let task: Task<([TrafficIncident], Date), Error>
        if let pending { task = pending }
        else {
            task = Task {
                var request = URLRequest(url: Self.endpoint)
                request.timeoutInterval = 8
                request.setValue("application/xml,text/xml", forHTTPHeaderField: "Accept")
                request.setValue("NaviAstra/1.1.139 (https://github.com/PetalMind/AstraNev)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw TrafficError.invalidResponse }
                if [429, 503].contains(http.statusCode) {
                    retryAfter = HTTPRetryDelay.date(from: http, minimum: 120)
                }
                guard http.statusCode == 200 else { throw TrafficError.sourceUnavailable("GDDKiA") }
                return try GDDKiAIncidentParser.decode(data, at: Date())
            }
            pending = task
        }
        defer { pending = nil }
        do {
            let (incidents, generatedAt) = try await task.value
            cached = (incidents, Date(), generatedAt)
            return filtered(incidents, boxes: boxes, observedAt: Date(), now: Date())
        } catch {
            retryAfter = max(retryAfter, Date().addingTimeInterval(120))
            // A failed refresh must not make an old bulletin look current.
            throw TrafficError.sourceUnavailable("GDDKiA")
        }
    }

    private func filtered(_ incidents: [TrafficIncident], boxes: [TrafficBoundingBox], observedAt: Date, now: Date) -> [TrafficIncident] {
        incidents.filter { incident in incident.isActive(at: now) && boxes.contains(where: { $0.contains(incident.coordinate) }) }
    }
}

extension TrafficBoundingBox {
    nonisolated func contains(_ point: Coordinate) -> Bool {
        (minLatitude...maxLatitude).contains(point.latitude) && (minLongitude...maxLongitude).contains(point.longitude)
    }
}

/// The published XML schema provides a point near the affected section's centre.
/// Never invent road geometry from its length or turn an approximate point into a reroute.
nonisolated final class GDDKiAIncidentParser: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var text = ""
    private var fields: [String: String] = [:]
    private var records: [[String: String]] = []
    private var generatedAt: Date?

    static func decode(_ data: Data, at now: Date) throws -> ([TrafficIncident], Date) {
        guard data.count <= 3_000_000, let xml = String(data: data, encoding: .utf8),
              !xml.localizedCaseInsensitiveContains("<!DOCTYPE"), !xml.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw TrafficError.invalidResponse
        }
        let delegate = GDDKiAIncidentParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let generated = delegate.generatedAt,
              (-300...86_400).contains(now.timeIntervalSince(generated)) else { throw TrafficError.invalidResponse }
        let incidents = delegate.records.compactMap { record -> TrafficIncident? in
            guard let lat = record["geo_lat"].flatMap(Double.init), let lon = record["geo_long"].flatMap(Double.init),
                  (48...56).contains(lat), (13...25).contains(lon),
                  let start = record["data_powstania"].flatMap(date),
                  let end = record["data_likwidacji"].flatMap(date), end > start, start <= now, end > now else { return nil }
            let closed = record["droga_zamknieta"] == "true"
            let category: TrafficIncidentCategory = closed ? .roadClosed : record["typ"] == "U" ? .roadWorks
                : record["typ"] == "W" ? .accident : .dangerousConditions
            let road = record["nr_drogi"] ?? ""
            let title = record["nazwa_odcinka"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? category.mapLabel
            let identity = [road, record["km"] ?? "", record["typ"] ?? "", record["data_powstania"] ?? ""].joined(separator: "|")
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let description = [road.isEmpty ? nil : "Droga " + road, title].compactMap { $0 }.joined(separator: " · ")
            return TrafficIncident(id: "gddkia/" + digest, description: description,
                coordinate: Coordinate(latitude: lat, longitude: lon), delaySeconds: nil,
                category: category, severity: .unknown, roadNumbers: road.isEmpty ? [] : [road], observedAt: now,
                startsAt: start, expiresAt: end, sources: [.gddkia], sourceUpdatedAt: generated)
        }
        return (incidents, generated)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        path.append(elementName); text = ""
        if path.count == 1, elementName == "utrudnienia" { generatedAt = attributes["gen"].flatMap(Self.date) }
        if elementName == "utr" { fields = [:] }
        if records.count >= 10_000 { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if path.contains("utr") { fields[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "utr" { records.append(fields) }
        if !path.isEmpty { path.removeLast() }
        text = ""
    }
}

/// A failed optional provider never discards another provider's valid response.
struct CombinedTrafficProvider: TrafficProvider {
    let tomTom: TomTomTrafficProvider?
    init(apiKey: String?) {
        tomTom = apiKey.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : TomTomTrafficProvider(apiKey: $0) }
    }
    func snapshot(near point: Coordinate, incidentRadiusMeters: Double) async throws -> TrafficSnapshot {
        let boxes = [TrafficBoundingBox.around(point, radiusMeters: incidentRadiusMeters)]
        async let shared = try? SharedRoadReportsClient.incidents(in: boxes)
        let live = try? await tomTom?.snapshot(near: point, incidentRadiusMeters: incidentRadiusMeters)
        let (additional, failure): ([TrafficIncident], String?) = (live?.incidentDataAvailable == true && live?.incidents.isEmpty == false)
            ? ([], nil) : await officialIncidents(in: boxes)
        let sharedIncidents = await shared
        try Task.checkCancellation()
        let local = LocalRoadReportStore.shared.incidents(in: boxes)
        let notices = [live?.partialError, failure,
                       SharedRoadReportsClient.endpoint != nil && sharedIncidents == nil ? "Wspólne zgłoszenia chwilowo niedostępne." : nil, tomTom == nil ? "Pomiar prędkości TomTom niedostępny bez klucza." : live == nil ? "Dane TomTom chwilowo niedostępne." : nil].compactMap { $0 }
        return TrafficSnapshot(flow: live?.flow,
            incidents: RoadIncidentMerger.merge((live?.incidents ?? []) + additional + local + (sharedIncidents ?? [])), updatedAt: Date(),
            partialError: notices.isEmpty ? nil : notices.joined(separator: " "), incidentDataAvailable: live?.incidentDataAvailable == true || failure == nil || !local.isEmpty ||
                (SharedRoadReportsClient.endpoint != nil && sharedIncidents != nil))
    }
    func incidents(in boxes: [TrafficBoundingBox]) async throws -> [TrafficIncident] {
        async let shared = try? SharedRoadReportsClient.incidents(in: boxes)
        let live = try? await tomTom?.incidents(in: boxes)
        let (additional, failure): ([TrafficIncident], String?) = live?.isEmpty == false ? ([], nil) : await officialIncidents(in: boxes)
        let sharedIncidents = await shared
        try Task.checkCancellation()
        if live == nil, failure != nil, sharedIncidents == nil || SharedRoadReportsClient.endpoint == nil,
           LocalRoadReportStore.shared.incidents(in: boxes).isEmpty { throw TrafficError.sourceUnavailable("ruchu i utrudnień") }
        return RoadIncidentMerger.merge((live ?? []) + additional + LocalRoadReportStore.shared.incidents(in: boxes) + (sharedIncidents ?? []))
    }
    private func officialIncidents(in boxes: [TrafficBoundingBox]) async -> ([TrafficIncident], String?) {
        guard boxes.contains(where: { $0.maxLatitude >= 48 && $0.minLatitude <= 56 && $0.maxLongitude >= 13 && $0.minLongitude <= 25 }) else {
            return ([], "GDDKiA nie obejmuje tego obszaru.")
        }
        do { return (try await GDDKiARoadIncidents.shared.incidents(in: boxes), nil) }
        catch { return ([], "GDDKiA: brak świeżego biuletynu utrudnień.") }
    }
    func routeFlowSamples(at queries: [RouteTrafficFlowQuery]) async -> [RouteTrafficFlowSample] {
        await tomTom?.routeFlowSamples(at: queries) ?? []
    }
    func rasterFlowTileURLTemplate(style: TrafficTileStyle) -> String? { tomTom?.rasterFlowTileURLTemplate(style: style) }
    func rasterIncidentTileURLTemplate(style: TrafficTileStyle) -> String? { tomTom?.rasterIncidentTileURLTemplate(style: style) }
}

nonisolated enum RoadIncidentMerger {
    static func merge(_ incidents: [TrafficIncident], at now: Date = Date()) -> [TrafficIncident] {
        var merged: [TrafficIncident] = []
        let sorted = incidents.filter { $0.isActive(at: now) }.sorted {
            ($0.sources.contains(.tomTom) ? 0 : $0.sources.contains(.gddkia) ? 1 : 2) <
            ($1.sources.contains(.tomTom) ? 0 : $1.sources.contains(.gddkia) ? 1 : 2)
        }
        for incident in sorted {
            let duplicate = merged.firstIndex { existing in
                if existing.id == incident.id { return true }
                let reports: Set<RoadIncidentSource> = [.local, .community]
                if !Set(existing.sources).isDisjoint(with: reports), !Set(incident.sources).isDisjoint(with: reports),
                   let left = existing.id.split(separator: "/").last.flatMap({ UUID(uuidString: String($0)) }),
                   let right = incident.id.split(separator: "/").last.flatMap({ UUID(uuidString: String($0)) }), left == right { return true }
                // Require a common road identifier, cause/category, nearby geometry
                // and compatible starts. Proximity alone never merges police reports.
                guard existing.category == incident.category, existing.cause == incident.cause,
                      !existing.roadNumbers.isEmpty,
                      !Set(existing.roadNumbers).isDisjoint(with: incident.roadNumbers),
                      existing.coordinate.distance(to: incident.coordinate) <= 40,
                      let existingStart = existing.startsAt, let incidentStart = incident.startsAt else { return false }
                return abs(existingStart.timeIntervalSince(incidentStart)) <= 7_200
            }
            if let duplicate {
                merged[duplicate].sources = Array(Set(merged[duplicate].sources + incident.sources)).sorted { $0.rawValue < $1.rawValue }
            } else { merged.append(incident) }
        }
        return merged
    }
}
