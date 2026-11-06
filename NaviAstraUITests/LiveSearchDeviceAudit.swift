import XCTest

/// Temporary, explicitly requested live-device observation. No fixtures or GPS override.
@MainActor
final class LiveSearchDeviceAudit: XCTestCase {
    func testFuelSearchWithActualDeviceServices() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Pomiar wymaga fizycznego iPhone’a.")
        #else
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "Blackmaks.NaviAstras.pl")
        app.activate()
        attach(app, name: "01-przed-wyszukiwaniem")
        let field = app.textFields["Szukaj miejsca lub adresu"]
        if !field.exists {
            let open = app.buttons["Szukaj miejsca lub połączenia"]
            if open.waitForExistence(timeout: 10), open.isHittable {
                open.tap()
            } else {
                let preview = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Trasa do ")).firstMatch
                if preview.exists, preview.isHittable { preview.tap() }
                let target = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Cel podróży:")).firstMatch
                guard target.waitForExistence(timeout: 5), target.isHittable else {
                    attachTree(app, name: "Brak-wejścia-do-wyszukiwania")
                    XCTFail("Nie znaleziono dostępnego wejścia do wyszukiwania.")
                    return
                }
                target.tap()
            }
        }
        let places = app.segmentedControls.buttons["Miejsca"]
        if places.exists, places.isHittable { places.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let clear = app.buttons["Wyczyść wyszukiwanie"]
        if clear.exists, clear.isHittable { clear.tap() }
        let scope = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Obszar wyszukiwania:")).firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.tap()
        app.buttons["Blisko mnie"].tap()
        guard app.buttons["Obszar wyszukiwania: Blisko mnie"].waitForExistence(timeout: 15) else {
            attach(app, name: "Brak-aktualnej-lokalizacji")
            attachTree(app, name: "Stan-bez-GPS")
            XCTFail("Brak potwierdzonego bieżącego GPS — nie można ocenić lokalności.")
            return
        }
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        let inputStarted = ProcessInfo.processInfo.systemUptime
        field.typeText("stacja benzynowa\n")
        let inputFinished = ProcessInfo.processInfo.systemUptime
        print("LIVE_SEARCH_INPUT_SECONDS \(inputFinished - inputStarted)")
        var screenshots = Set<Int>()
        repeat {
            let elapsed = ProcessInfo.processInfo.systemUptime - inputFinished
            try record(app, stage: "lista", elapsed: elapsed)
            let bucket = elapsed < 3 ? 0 : elapsed < 10 ? 1 : 2
            if screenshots.insert(bucket).inserted { attach(app, name: "Lista-\(Int(elapsed))-sekund") }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        } while ProcessInfo.processInfo.systemUptime - inputFinished < 15
        try record(app, stage: "lista-koniec", elapsed: ProcessInfo.processInfo.systemUptime - inputFinished)
        attach(app, name: "Końcowy-ekran-stacji")
        attachTree(app, name: "Końcowe-wyniki")
        app.swipeUp()
        try record(app, stage: "po-przewinięciu", elapsed: ProcessInfo.processInfo.systemUptime - inputFinished)
        attach(app, name: "Dalsze-wyniki")
        app.swipeDown()
        XCTAssertEqual(app.state, .runningForeground)
        #endif
    }

    func testRawMapKitMetadataAfterSearch() async {
        await MapKitFuelDiagnostics.run()
    }

    private func record(_ app: XCUIApplication, stage: String, elapsed: Double) throws {
        let snapshot = try app.snapshot()
        var elements: [[String: Any]] = []
        func visit(_ node: any XCUIElementSnapshot) {
            if [.button, .staticText, .textField, .activityIndicator].contains(node.elementType), !node.label.isEmpty,
               node.frame.intersects(snapshot.frame), !node.frame.isEmpty {
                elements.append(["type": node.elementType.rawValue, "label": node.label,
                                 "value": String(describing: node.value ?? ""),
                                 "y": node.frame.minY, "height": node.frame.height])
            }
            node.children.forEach(visit)
        }
        visit(snapshot)
        let data = try JSONSerialization.data(withJSONObject: ["stage": stage, "seconds": elapsed,
                                                               "elements": elements], options: [.sortedKeys])
        print("LIVE_SEARCH_OBSERVATION " + String(decoding: data, as: UTF8.self))
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachTree(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import Foundation
import MapKit

// Paste at file scope in the temporary UI test. After the measured UI flow:
// await MapKitFuelDiagnostics.run()
// This diagnostics-only runner prints raw Apple metadata; it does not mutate the app.
@MainActor
enum MapKitFuelDiagnostics {
    static func run() async {
        let center = CLLocationCoordinate2D(latitude: 51.7098273, longitude: 19.4889357)
        let radius = 3_000.0
        let nearby = MKLocalPointsOfInterestRequest(center: center,
            radius: min(radius, MKLocalPointsOfInterestRequest.maxRadius))
        nearby.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation])
        await dump(MKLocalSearch(request: nearby), label: "nearby_poi_gasStation",
                   center: center, radius: min(radius, MKLocalPointsOfInterestRequest.maxRadius))

        let canonical = MKLocalSearch.Request()
        canonical.naturalLanguageQuery = "gas station"
        canonical.resultTypes = [.pointOfInterest]
        canonical.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation])
        canonical.region = MKCoordinateRegion(center: center,
            latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        canonical.regionPriority = .required
        await dump(MKLocalSearch(request: canonical), label: "text_gas_station_filtered",
                   center: center, radius: radius)

        let brand = MKLocalSearch.Request()
        brand.naturalLanguageQuery = "ORLEN"
        brand.resultTypes = [.pointOfInterest]
        brand.region = canonical.region
        brand.regionPriority = .required
        await dump(MKLocalSearch(request: brand), label: "brand_orlen_unfiltered",
                   center: center, radius: radius)
    }

    private static func dump(_ search: MKLocalSearch, label: String,
                             center: CLLocationCoordinate2D, radius: Double) async {
        let started = Date()
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            search.cancel()
        }
        defer { timeout.cancel() }
        var payload: [String: Any] = ["request": label,
            "centerLat": center.latitude, "centerLon": center.longitude,
            "radius": radius, "appleMaxRadius": MKLocalPointsOfInterestRequest.maxRadius]
        do {
            let response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await search.start()
            } onCancel: {
                Task { @MainActor in search.cancel() }
            }
            let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
            payload["items"] = response.mapItems.map { item -> [String: Any] in
                let coordinate = item.location.coordinate
                let distance = origin.distance(from: item.location)
                return ["name": item.name ?? "<nil>",
                    "category": item.pointOfInterestCategory?.rawValue ?? "<nil>",
                    "address": item.address?.fullAddress ?? "<nil>",
                    "city": item.addressRepresentations?.cityName ?? "<nil>",
                    "providerID": item.identifier?.rawValue ?? "<nil>",
                    "lat": coordinate.latitude, "lon": coordinate.longitude,
                    "distanceToCenter": distance, "withinRadius": distance <= radius,
                    "acceptedByStrictCategory": item.pointOfInterestCategory == .gasStation]
            }
        } catch {
            payload["error"] = String(describing: error)
        }
        payload["seconds"] = Date().timeIntervalSince(started)
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print("MAPKIT_FUEL_DIAGNOSTIC " + json)
        }
    }
}
