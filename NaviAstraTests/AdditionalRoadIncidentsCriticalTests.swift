import Foundation
import Testing
@testable import NaviAstra

@MainActor
struct AdditionalRoadIncidentsCriticalTests {
    @Test func officialBulletinsRejectStaleFutureAndUnsafeXMLAndKeepPointGeometry() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!
        func xml(generated: String, end: String = "2026-10-27T16:00:00Z") -> Data {
            Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <utrudnienia gen="\(generated)"><utr><typ>U</typ><nr_drogi>A2</nr_drogi><km>100.0</km>
            <geo_lat>52.23</geo_lat><geo_long>21.01</geo_long><nazwa_odcinka>Roboty przy węźle</nazwa_odcinka>
            <data_powstania>2026-10-27T10:00:00Z</data_powstania><data_likwidacji>\(end)</data_likwidacji>
            <droga_zamknieta>true</droga_zamknieta></utr></utrudnienia>
            """.utf8)
        }
        let (incidents, _) = try GDDKiAIncidentParser.decode(xml(generated: "2026-10-27T11:50:00Z"), at: now)
        let incident = try #require(incidents.first)
        #expect(incident.sources == [.gddkia])
        #expect(incident.category == .roadClosed)
        #expect(incident.geometry.isEmpty)
        #expect(!incident.affectsRouting && !incident.isRoadClosure)
        #expect(incident.routingDelaySeconds == nil)
        for generated in ["2026-10-20T12:00:00Z", "2026-10-28T12:00:00Z"] {
            #expect(throws: TrafficError.self) { try GDDKiAIncidentParser.decode(xml(generated: generated), at: now) }
        }
        #expect(try GDDKiAIncidentParser.decode(xml(generated: "2026-10-27T11:50:00Z", end: "2026-10-27T11:00:00Z"), at: now).0.isEmpty)
        let malicious = Data("<!DOCTYPE x [<!ENTITY y SYSTEM 'file:///etc/passwd'>]><utrudnienia/>".utf8)
        #expect(throws: TrafficError.self) { try GDDKiAIncidentParser.decode(malicious, at: now) }
    }

    @Test func unverifiedReportsExpirePersistAndNeverInventTrafficOrReroutes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("reports.json")
        let store = LocalRoadReportStore(fileURL: file)
        let now = Date()
        let point = Coordinate(latitude: 52.23, longitude: 21.01)
        let report = try store.add(kind: .police, coordinate: point, at: now)
        let incident = report.incident(at: now)
        #expect(incident.cause == .policeCheckpoint)
        #expect(!incident.affectsRouting && incident.routingDelaySeconds == nil)
        #expect(!LocalRoadReportStore.valid(report, at: now.addingTimeInterval(1_801)))
        #expect(LocalRoadReportStore(fileURL: file).reports.count == 1)
        let shared = report.incident(source: .community, at: now)
        let merged = RoadIncidentMerger.merge([incident, shared], at: now)
        #expect(merged.count == 1)
        #expect(Set(merged[0].sources) == Set([.local, .community]))
        #expect(!merged[0].affectsRouting)
        try store.remove(report.id)
        #expect(LocalRoadReportStore(fileURL: file).reports.isEmpty)
    }

    @Test func duplicateIndependentSourcesKeepReliableGeometryAndSingleDelay() throws {
        let now = Date(), point = Coordinate(latitude: 52.23, longitude: 21.01)
        let tomTom = TrafficIncident(id: "tomtom/1", description: "Wypadek", coordinate: point, delaySeconds: 90,
            category: .accident, severity: .major, geometry: [point, Coordinate(latitude: 52.24, longitude: 21.01)],
            roadNumbers: ["A2"], observedAt: now, startsAt: now, expiresAt: now.addingTimeInterval(600))
        let official = TrafficIncident(id: "gddkia/1", description: "Wypadek", coordinate: point, delaySeconds: nil,
            category: .accident, severity: .unknown, roadNumbers: ["A2"], observedAt: now,
            startsAt: now, expiresAt: now.addingTimeInterval(1_800), sources: [.gddkia])
        let merged = RoadIncidentMerger.merge([official, tomTom], at: now)
        #expect(merged.count == 1)
        #expect(merged[0].geometry == tomTom.geometry)
        #expect(merged[0].routingDelaySeconds == 90)
        #expect(merged[0].expiresAt == tomTom.expiresAt)
        #expect(Set(merged[0].sources) == Set([.tomTom, .gddkia]))
    }
}
