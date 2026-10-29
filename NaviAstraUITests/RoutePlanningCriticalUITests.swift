import XCTest

/// Regression coverage for the physical-device stack overflow when SwiftUI
/// instantiated the destination and waypoint forms, before a route was ready.
@MainActor
final class RoutePlanningCriticalUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEndpointFormsInLightAndDark() throws {
        for appearance in ["Light", "Dark"] {
            for waypoints in [0, 8] {
                let app = launchScenario(waypoints: waypoints, appearance: appearance)
                XCTAssertTrue(app.buttons["Wyznacz trasę"].waitForExistence(timeout: 20),
                              "Formularz trasy nie pojawił się dla \(waypoints) przystanków (\(appearance)).")
                XCTAssertTrue(app.buttons["Punkt startowy: Łódź — początek kontroli"].exists)
                XCTAssertTrue(app.buttons["Cel podróży: Łódź — cel kontroli"].exists)
                let removeButtons = app.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH %@", "Usuń przystanek "))
                XCTAssertEqual(removeButtons.count, waypoints,
                               "Formularz powinien zachować wszystkie przystanki.")
                if waypoints == 8 {
                    XCTAssertTrue(app.buttons["Usuń przystanek 8"].exists)
                }
                attachScreenshot(app, name: "Formularz-\(appearance)-\(waypoints)-przystanków")
                XCTAssertEqual(app.state, .runningForeground,
                               "Aplikacja zakończyła się podczas renderowania formularza.")
                app.terminate()
            }
        }
    }

    func testRealRouteCalculationDoesNotCrash() throws {
        let app = launchScenario(waypoints: 0, appearance: "Light")
        defer { app.terminate() }
        let calculate = app.buttons["Wyznacz trasę"]
        XCTAssertTrue(calculate.waitForExistence(timeout: 20))
        calculate.tap()

        let start = app.buttons.matching(NSPredicate(format: "label IN %@", [
            "Rozpocznij nawigację", "Nawiguj do punktu startowego", "Rozpocznij"
        ])).firstMatch
        let retry = app.buttons.matching(NSPredicate(format: "label IN %@", [
            "Spróbuj ponownie", "Ponów"
        ])).firstMatch
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state != .runningForeground || (start.exists && start.isEnabled) || retry.exists
        }, object: nil)
        let result = XCTWaiter.wait(for: [finished], timeout: 90)

        XCTAssertEqual(app.state, .runningForeground,
                       "Aplikacja zakończyła się podczas rzeczywistego wyznaczania trasy.")
        attachScreenshot(app, name: "Rzeczywiste-wyznaczanie-trasy")
        XCTAssertEqual(result, .completed, "Usługa nie zakończyła wyznaczania trasy w ciągu 90 sekund.")
        if start.exists && start.isEnabled { return }

        let messages = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { text in
            ["Nie udało", "Nie można", "Nie znaleziono", "Serwer", "Czekam", "Brak połączenia",
             "Brak trasy", "Usługa", "niedostęp", "Przekroczono"].contains { text.contains($0) }
        }
        XCTAssertTrue(retry.exists && !messages.isEmpty,
                      "Błąd usługi powinien mieć czytelny polski komunikat i możliwość ponowienia.")
        throw XCTSkip("Formularz i obsługa błędu pozostały aktywne; rzeczywista usługa nie zwróciła trasy: \(messages.joined(separator: " · "))")
    }

    private func launchScenario(waypoints: Int, appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["NAVIASTRA_ROUTE_UI_AUDIT"] = "1"
        app.launchEnvironment["NAVIASTRA_ROUTE_UI_WAYPOINTS"] = String(waypoints)
        // NSArgumentDomain is process-local and does not change saved preferences.
        app.launchArguments += ["-AppleInterfaceStyle", appearance, "-mapAppearance", "auto"]
        app.launch()
        return app
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
