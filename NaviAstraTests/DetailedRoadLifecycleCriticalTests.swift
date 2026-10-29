#if os(iOS)
import Foundation
import MapLibre
import Testing
import UIKit
@testable import NaviAstra

/// Critical integration of the real MapLibre style, geometry publication and cancellation.
@Suite(.serialized)
@MainActor
struct DetailedRoadLifecycleCriticalTests {
    enum Scenario: String, CaseIterable, Sendable { case freshCache, staleCacheWithFailure, cancelledDownload }

    private actor Provider: DetailedRoadDataProvider {
        let scenario: Scenario
        var requests = 0
        nonisolated var sourceConfiguration: DetailedRoadSourceConfiguration { .shapes }
        init(_ scenario: Scenario) { self.scenario = scenario }
        func cachedData(in query: DetailedRoadQuery) async -> DetailedRoadData? {
            scenario == .cancelledDownload ? nil : .roads(snapshot())
        }
        func data(in query: DetailedRoadQuery) async throws -> DetailedRoadData {
            requests += 1
            if scenario == .staleCacheWithFailure { throw URLError(.notConnectedToInternet) }
            try await Task.sleep(for: .seconds(2))
            try Task.checkCancellation()
            return .roads(snapshot())
        }
        private func snapshot() -> DetailedRoadSnapshot {
            let meters = 6_371_008.8 * Double.pi / 180
            func point(_ x: Double) -> DetailedRoad.Point {
                .init(latitude: 52, longitude: 19 + x / (meters * cos(52 * .pi / 180)))
            }
            let roads = [DetailedRoad(id: 1, points: [point(-90), point(0), point(90)],
                tags: ["highway": "primary", "oneway": "yes", "lanes": "2", "width": "6.4", "turn:lanes": "through|right"], nodeIDs: [1, 2, 3])]
            return DetailedRoadSnapshot(roads: roads,
                fetchedAt: Date().addingTimeInterval(scenario == .staleCacheWithFailure ? -172_800 : 0),
                revision: "lifecycle-" + scenario.rawValue)
        }
    }

    @MainActor
    private final class MapHost: NSObject, MLNMapViewDelegate {
        let map: MLNMapView
        let window: UIWindow
        var loads = 0
        override init() {
            map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 720))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: map.frame)
            super.init()
            map.delegate = self
            let controller = UIViewController(); controller.view.addSubview(map)
            window.rootViewController = controller; window.makeKeyAndVisible()
            map.setCenter(CLLocationCoordinate2D(latitude: 52, longitude: 19), zoomLevel: 18, animated: false)
        }
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) { loads += 1 }
        func close() { map.delegate = nil; window.isHidden = true; window.rootViewController = nil }
    }

    private func waitUntil(_ stage: String, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !(await condition()) {
            try #require(Date() < deadline, Comment(rawValue: "Przekroczony czas kontroli mapy: " + stage))
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private func layers(_ map: MLNMapView) -> [MLNStyleLayer] {
        map.style?.layers.filter { $0.identifier.hasPrefix("naviastra-detailed-roads-") } ?? []
    }
    private func hasSurface(_ map: MLNMapView) -> Bool {
        (map.style?.source(withIdentifier: "naviastra-detailed-roads-surface-source") as? MLNShapeSource)?.shape != nil
    }

    private func installNavigationOverlays(on map: MLNMapView) throws {
        let style = try #require(map.style)
        let source = MLNShapeSource(identifier: "overlay-regression-source", shape: nil, options: nil)
        style.addSource(source)
        // A minimal style deliberately has no transportation anchor. This must
        // not cause asynchronously installed asphalt to cover route or names.
        style.addLayer(MLNLineStyleLayer(identifier: "naviastra-active-route-line", source: source))
        style.addLayer(MLNSymbolStyleLayer(identifier: "regression-street-names", source: source))
    }

    private func checkNavigationVisibility(on map: MLNMapView) throws {
        let style = try #require(map.style)
        let all = style.layers
        let routeIndex = try #require(all.firstIndex { $0.identifier == "naviastra-active-route-line" })
        let namesIndex = try #require(all.firstIndex { $0.identifier == "regression-street-names" })
        let roadIndices = all.indices.filter { all[$0].identifier.hasPrefix("naviastra-detailed-roads-") }
        #expect(!roadIndices.isEmpty)
        #expect(roadIndices.allSatisfy { $0 < min(routeIndex, namesIndex) })
        let json = try #require(JSONSerialization.jsonObject(with: Data(style.styleJSON.utf8)) as? [String: Any])
        let serialized = try #require(json["layers"] as? [[String: Any]])
        let asphalt = serialized.filter {
            let id = $0["id"] as? String ?? ""
            return id.hasPrefix("naviastra-detailed-roads-") && (id.hasSuffix("-surface") || id.hasSuffix("-casing"))
        }
        #expect(!asphalt.isEmpty)
        for layer in asphalt {
            let paint = try #require(layer["paint"] as? [String: Any])
            let opacity = try #require(paint["fill-opacity"] as? [Any])
            let maximum = try #require(opacity.last as? Double)
            // Opaque pavement writes coplanar depth and can fragment an otherwise
            // continuous route in perspective. It must stay in the blended pass.
            #expect(maximum > 0.9 && maximum < 1)
            #expect(paint["fill-antialias"] as? Bool == true)
        }
    }

    @Test(arguments: Scenario.allCases)
    func publicationStyleReplacementDisableResumeAndCancellation(_ scenario: Scenario) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let style = ##"{"version":8,"sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#182128"}}]}"##
        let first = folder.appendingPathComponent("first.json"), second = folder.appendingPathComponent("second.json")
        try Data(style.utf8).write(to: first); try Data(style.utf8).write(to: second)
        let host = MapHost(); defer { host.close() }
        let provider = Provider(scenario), renderer = DetailedRoadRenderer(provider: provider)
        defer { renderer.stop() }
        host.map.styleURL = first
        try await waitUntil("pierwszy styl") { host.loads >= 1 }
        try installNavigationOverlays(on: host.map)
        renderer.didLoadStyle(on: host.map)
        try checkNavigationVisibility(on: host.map)
        renderer.update(on: host.map, dark: true, enabled: true)
        if scenario == .cancelledDownload {
            try await waitUntil("pobieranie") { await provider.requests > 0 }
            renderer.update(on: host.map, dark: true, enabled: false)
            try await Task.sleep(for: .milliseconds(2200))
            #expect(!hasSurface(host.map))
            #expect(layers(host.map).allSatisfy { !$0.isVisible })
            return
        }
        try await waitUntil("publikacja nawierzchni") { hasSurface(host.map) }
        #expect(layers(host.map).count == 162)
        #expect(layers(host.map).allSatisfy { $0.isVisible })
        try checkNavigationVisibility(on: host.map)
        // Another map renderer may install an overlay after initial setup.
        // Updating retained road sources must restore the same ordering.
        let currentStyle = try #require(host.map.style)
        let routeOverlay = try #require(currentStyle.layer(withIdentifier: "naviastra-active-route-line"))
        let firstRoad = try #require(layers(host.map).first)
        currentStyle.removeLayer(routeOverlay)
        currentStyle.insertLayer(routeOverlay, below: firstRoad)
        renderer.update(on: host.map, dark: true, enabled: true)
        try checkNavigationVisibility(on: host.map)
        let sprite = "naviastra-detailed-roads-arrow-through"
        #expect(host.map.style?.image(forName: sprite) != nil)
        if scenario == .staleCacheWithFailure { try await waitUntil("pobieranie") { await provider.requests > 0 } }
        renderer.update(on: host.map, dark: false, enabled: false)
        #expect(layers(host.map).allSatisfy { !$0.isVisible })
        let loaded = host.loads
        host.map.styleURL = second
        try await waitUntil("zamiana stylu") { host.loads > loaded }
        try installNavigationOverlays(on: host.map)
        renderer.didLoadStyle(on: host.map)
        try checkNavigationVisibility(on: host.map)
        #expect(hasSurface(host.map))
        #expect(layers(host.map).allSatisfy { !$0.isVisible })
        #expect(host.map.style?.image(forName: sprite) != nil)
        renderer.update(on: host.map, dark: false, enabled: true)
        #expect(layers(host.map).allSatisfy { $0.isVisible })
        #expect(hasSurface(host.map))
        try await Task.sleep(for: .milliseconds(800))
        let requests = await provider.requests
        #expect(requests == (scenario == .freshCache ? 0 : 1))
    }

    @Test func movingCameraAllowsAnInFlightDownloadToPublish() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("moving.json")
        try Data(##"{"version":8,"sources":{},"layers":[{"id":"background","type":"background"}]}"##.utf8).write(to: file)
        let host = MapHost(); defer { host.close() }
        let provider = Provider(.cancelledDownload), renderer = DetailedRoadRenderer(provider: provider)
        defer { renderer.stop() }
        host.map.styleURL = file
        try await waitUntil("styl przy ruchu kamery") { host.loads >= 1 }
        renderer.didLoadStyle(on: host.map)
        renderer.update(on: host.map, dark: false, enabled: true)
        try await waitUntil("pobieranie przy ruchu kamery") { await provider.requests > 0 }
        // Each move crosses the quantized query margin before the two-second
        // response arrives. Viewport cancellation previously starved publication.
        for index in 1...12 {
            host.map.setCenter(CLLocationCoordinate2D(latitude: 52, longitude: 19 + Double(index) * 0.004),
                               zoomLevel: 18, animated: false)
            renderer.update(on: host.map, dark: false, enabled: true)
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(hasSurface(host.map))
        let requests = await provider.requests
        #expect(requests <= 2)
    }

    @Test func cachedSurfacesRemainUsableDuringAnOutageAndPartialCoverageStillRefreshes() async throws {
        struct Entry: Encodable {
            let query: DetailedRoadQuery
            let endpoint: String
            let roads: [DetailedRoad]
            let fetchedAt: Date
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("NaviAstra/DetailedRoads/v2.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let configured = UserDefaults.standard.string(forKey: "overpassServer").flatMap(URL.init(string:))
        let endpoint = configured.flatMap {
            ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil ? $0.absoluteString : nil
        } ?? "https://overpass-api.de/api/interpreter"
        let first = DetailedRoadQuery(south: 52, west: 19, north: 52.01, east: 19.01)
        let second = DetailedRoadQuery(south: 52, west: 19.01, north: 52.01, east: 19.02)
        func road(_ id: Int64) -> DetailedRoad {
            .init(id: id, points: [.init(latitude: 52.001, longitude: 19.001),
                                  .init(latitude: 52.002, longitude: 19.002)],
                  tags: ["highway": "primary", "lanes": "2"], nodeIDs: nil)
        }
        let expired = DetailedRoadQuery(south: 50, west: 20, north: 50.01, east: 20.01)
        let entries = [
            Entry(query: first, endpoint: endpoint, roads: [road(1)], fetchedAt: .now.addingTimeInterval(-10 * 86_400)),
            Entry(query: second, endpoint: endpoint, roads: [road(2)], fetchedAt: .now.addingTimeInterval(-3_600)),
            Entry(query: expired, endpoint: endpoint, roads: [road(3)], fetchedAt: .now.addingTimeInterval(-31 * 86_400))
        ]
        try JSONEncoder().encode(entries).write(to: file)
        let provider = OverpassDetailedRoadProvider(cacheDirectory: folder)
        guard case .roads(let cached)? = await provider.cachedData(in: first) else {
            Issue.record("Utracono zachowaną nawierzchnię podczas awarii sieci"); return
        }
        #expect(cached.roads.map(\.id) == [1])
        #expect(cached.coversQuery && !cached.isFresh)
        let partial = DetailedRoadQuery(south: 52, west: 19.005, north: 52.01, east: 19.025)
        guard case .roads(let merged)? = await provider.cachedData(in: partial) else {
            Issue.record("Przesunięcie kadru usunęło dostępne fragmenty dróg"); return
        }
        #expect(merged.roads.map(\.id) == [1, 2])
        #expect(!merged.coversQuery && !merged.isFresh)
        let removed = await provider.cachedData(in: expired)
        #expect(removed == nil)
    }
}
#endif
