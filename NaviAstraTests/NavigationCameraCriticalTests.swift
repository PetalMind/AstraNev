import Foundation
import Testing
@testable import NaviAstra

@MainActor
struct NavigationCameraCriticalTests {
    @Test func completeDrivingTrajectoriesKeepTurningAndFramingContinuous() throws {
        // Check the viewport-adjusted cruise frame too: fitting must not undo
        // the close, behind-the-vehicle perspective requested by the planner.
        let straightRoad = geometry([point(), point(north: 2_000)])
        let portraitPadding = CameraPadding(top: 190, left: 24, bottom: 240, right: 24)
        for (speed, minimumZoom) in [(0.0, 17.5), (11.0, 16.6), (25.0, 15.8), (41.6, 15.4)] {
            let engine = NavigationCameraEngine()
            engine.setRouteGeometry(straightRoad)
            let cruise = try #require(engine.update(input(straightRoad,
                distance: 100, speed: speed, time: 0)))
            let fitted = cruise.fittingViewport(portraitPadding, width: 390, height: 844)
            expectUsable(cruise)
            expectUsable(fitted)
            #expect(fitted.zoom >= minimumZoom,
                    "Dopasowanie prostej drogi nie może oddalać kamery do widoku przeglądowego")
            #expect(fitted.pitch >= 50,
                    "Jazda na wprost wymaga perspektywy zza pojazdu także po dopasowaniu paneli")
            #expect(cruise.anchorFraction >= 0.8,
                    "Znacznik musi pozostawiać większość dostępnej mapy na drogę przed pojazdem")
            let markerY = (fitted.padding.top + 844 - fitted.padding.bottom) / 2
            #expect(844 - portraitPadding.bottom - markerY >= 56,
                    "Bliższa kamera musi zachować odstęp znacznika od dolnego panelu")
        }

        let roundaboutArc = (0...18).map { index in
            let angle = Double.pi - Double(index) * Double.pi / 12
            return point(east: 25 + 25 * cos(angle), north: 560 + 25 * sin(angle))
        }
        let scenarios: [DrivingScenario] = [
            .init(name: "Prosta", coordinates: [point(), point(north: 1_200)],
                  turnIndex: nil, turnAngle: nil),
            .init(name: "Skręt 90°", coordinates: [point(), point(north: 600),
                  point(east: 650, north: 600)], turnIndex: 1, turnAngle: 90),
            .init(name: "Nawrót", coordinates: [point(), point(north: 600),
                  point(east: 20, north: 620), point(east: 40, north: 600),
                  point(east: 40)], turnIndex: 1, turnAngle: 180),
            .init(name: "Rondo", coordinates: [point()] + roundaboutArc +
                  [point(east: -400, north: 535)], turnIndex: 1, turnAngle: -90,
                  roundabout: true, exitIndex: roundaboutArc.count)
        ]

        for scenario in scenarios {
            let geometry = geometry(scenario.coordinates)
            let engine = NavigationCameraEngine()
            engine.setRouteGeometry(geometry)
            let turnDistance = scenario.turnIndex.map { geometry.cumulativeDistances[$0] }
            let passedDistance = scenario.exitIndex.map { geometry.cumulativeDistances[$0] }
                ?? turnDistance.map { $0 + 15 }
            var previous: CameraIntent?
            var initial: CameraIntent?
            var minimumPitch = Double.infinity
            var maximumBearingStep = 0.0
            var maximumZoomStep = 0.0
            var maximumPitchStep = 0.0
            var maximumAnchorStep = 0.0
            let speed = 11.0
            let interval = 0.2
            let steps = Int((geometry.length - 100) / (speed * interval))

            for step in 0...steps {
                let distance = Double(step) * speed * interval
                let hasPassed = passedDistance.map { distance > $0 } ?? false
                let nextDistance = turnDistance.map { hasPassed ? 700 : max(0, $0 - distance) }
                let input = input(geometry, distance: distance, speed: speed,
                    time: Double(step) * interval,
                    maneuverDistance: nextDistance,
                    angle: hasPassed ? 0 : scenario.turnAngle,
                    roundabout: scenario.roundabout && !hasPassed,
                    maneuverIndex: hasPassed ? scenario.coordinates.count - 1 : scenario.turnIndex)
                let intent = try #require(engine.update(input), "Brak kadru: \(scenario.name)")
                expectUsable(intent)
                #expect(intent.followCoordinate == input.matchedCoordinate)
                #expect(!intent.framingCoordinates.isEmpty)
                if let previous {
                    maximumBearingStep = max(maximumBearingStep, angleDifference(previous.bearing, intent.bearing))
                    maximumZoomStep = max(maximumZoomStep, abs(previous.zoom - intent.zoom))
                    maximumPitchStep = max(maximumPitchStep, abs(previous.pitch - intent.pitch))
                    maximumAnchorStep = max(maximumAnchorStep, abs(previous.anchorFraction - intent.anchorFraction))
                } else {
                    initial = intent
                }
                minimumPitch = min(minimumPitch, intent.pitch)
                previous = intent
            }

            // These are perceptual continuity limits, independent of the filter's coefficients.
            #expect(maximumBearingStep < 12, "Nagły obrót: \(scenario.name)")
            #expect(maximumZoomStep < 0.25, "Nagła zmiana skali: \(scenario.name)")
            #expect(maximumPitchStep < 5, "Nagłe pochylenie: \(scenario.name)")
            #expect(maximumAnchorStep < 0.03, "Skok pozycji strzałki: \(scenario.name)")
            let final = try #require(previous)
            let finalDistance = Double(steps) * speed * interval
            let exitBearing = try #require(geometry.bearing(at: finalDistance, lookAhead: 20))
            #expect(angleDifference(final.bearing, exitBearing) < 25,
                    "Kamera nie dogoniła kierunku drogi: \(scenario.name)")
            if scenario.turnIndex != nil {
                #expect(minimumPitch < (initial?.pitch ?? 0) - 3,
                        "Brak czytelniejszego kadru skrzyżowania: \(scenario.name)")
            } else {
                #expect(maximumBearingStep < 0.1)
            }
        }

        // Two decisions 60 m apart belong to one readable scene, including the
        // exit after the second turn. Passing the first must not release the zoom.
        let closeTurns = geometry([point(), point(north: 600),
            point(east: 60, north: 600), point(east: 60, north: 1_500)])
        let closeEngine = NavigationCameraEngine()
        closeEngine.setRouteGeometry(closeTurns)
        let firstTurn = closeTurns.cumulativeDistances[1]
        let secondTurn = closeTurns.cumulativeDistances[2]
        let entry = try #require(closeEngine.update(input(closeTurns,
            distance: firstTurn - 40, speed: 10, time: 0,
            maneuverDistance: 40, angle: 90, maneuverIndex: 1,
            followingManeuverDistance: secondTurn - firstTurn + 40)))
        #expect(entry.framingCoordinates.contains { $0.latitude > point(north: 610).latitude },
                "Wspólny kadr musi zawierać wyjście za drugim bliskim skrętem")
        var lastJunction = entry
        var firstRecovery: CameraIntent?
        for step in 1...75 {
            let distance = firstTurn - 40 + Double(step) * 2
            let passedFirst = distance > firstTurn
            let passedSecond = distance > secondTurn
            let intent = try #require(closeEngine.update(input(closeTurns,
                distance: distance, speed: 10, time: Double(step) * 0.2,
                maneuverDistance: passedSecond ? 700 :
                    (passedFirst ? secondTurn - distance : firstTurn - distance),
                angle: passedSecond ? 0 : (passedFirst ? -90 : 90),
                maneuverIndex: passedSecond ? 3 : (passedFirst ? 2 : 1),
                followingManeuverDistance: passedFirst ? nil : secondTurn - distance)))
            expectUsable(intent)
            if !passedSecond {
                #expect(intent.zoom >= entry.zoom - 0.15,
                        "Między bliskimi skrętami kamera nie może oddalać kadru")
                lastJunction = intent
            } else {
                if firstRecovery == nil { firstRecovery = intent }
                if distance - secondTurn < 16 {
                    #expect(intent.zoom >= lastJunction.zoom - 0.15)
                    #expect(intent.pitch <= lastJunction.pitch + 3,
                            "Wyjście ze skrzyżowania wymaga krótkiego podtrzymania kadru")
                }
            }
        }
        var settled = try #require(firstRecovery)
        for step in 76...200 {
            settled = try #require(closeEngine.update(input(closeTurns,
                distance: firstTurn - 40 + Double(step) * 2, speed: 10,
                time: Double(step) * 0.2, maneuverDistance: 700, angle: 0, maneuverIndex: 3)))
        }
        #expect(settled.pitch > lastJunction.pitch + 4,
                "Po sekwencji manewrów kamera musi odzyskać dalszą perspektywę")
        #expect(settled.zoom < lastJunction.zoom - 0.2)
    }

    @Test func stopSignalLossAndManualExplorationPreserveNavigationContext() throws {
        let geometry = geometry([point(), point(north: 600), point(east: 700, north: 600)])
        let engine = NavigationCameraEngine()
        engine.setRouteGeometry(geometry)
        var latest: CameraIntent?
        for step in 0...30 {
            latest = engine.update(input(geometry, distance: 400 + Double(step) * 2.4,
                speed: 12, time: Double(step) * 0.2,
                maneuverDistance: 200 - Double(step) * 2.4, angle: 90, maneuverIndex: 1))
        }
        let moving = try #require(latest)
        for step in 1...30 {
            let stopped = try #require(engine.update(input(geometry, distance: 472,
                speed: 0, time: 6 + Double(step) * 0.2, course: Double(step * 17 % 360),
                maneuverDistance: 128, angle: 90, maneuverIndex: 1)))
            expectUsable(stopped)
            #expect(angleDifference(stopped.bearing, moving.bearing) < 0.001,
                    "Kompas nie może obracać mapy podczas postoju")
            if step == 1 {
                #expect(abs(stopped.zoom - moving.zoom) < 0.15,
                        "Zatrzymanie nie może natychmiast zmienić skali skrzyżowania")
            }
            latest = stopped
        }
        let stopped = try #require(latest)
        for step in 1...20 {
            let weak = try #require(engine.update(input(geometry, distance: 472 + Double(step) * 9,
                speed: 20, time: 12 + Double(step) * 0.2, course: 180,
                maneuverDistance: max(0, 128 - Double(step) * 9), angle: 90,
                state: .weakGPS, maneuverIndex: 1)))
            expectUsable(weak)
            #expect(angleDifference(weak.bearing, stopped.bearing) < 0.001,
                    "Niepewna pozycja nie może obracać mapy przez skrzyżowanie")
        }

        let restoredInput = input(geometry, distance: 700, speed: 12, time: 20,
                                  maneuverDistance: 500, angle: 0, maneuverIndex: 2)
        engine.setMode(.freeLook)
        #expect(engine.update(restoredInput) == nil)
        engine.setMode(.overview)
        #expect(engine.update(restoredInput) == nil)
        engine.setMode(.following)
        let restored = try #require(engine.update(restoredInput))
        expectUsable(restored)
        #expect(restored.followCoordinate == restoredInput.matchedCoordinate)
        #expect(angleDifference(restored.bearing, 90) < 10)
        #expect((restored.animationDuration ?? 0) > 0)
        #expect((restored.animationDuration ?? 10) <= 1)

        engine.clearRoute()
        #expect(engine.update(restoredInput) == nil)
        engine.setRouteGeometry(geometry)
        engine.resetForNavigation()
        let restarted = try #require(engine.update(input(geometry, distance: 0,
            speed: 0, time: 25, state: .startingNavigation)))
        #expect(angleDifference(restarted.bearing, 0) < 10)
        #expect((restarted.animationDuration ?? 0) > 0)

        // Recenter while north crosses through 360° must choose the short turn
        // and publish a normalized heading already in the first frame.
        let northBend = self.geometry([point(), point(north: 30),
                                      point(east: -120, north: 300)])
        engine.setRouteGeometry(northBend)
        engine.setMode(.freeLook)
        engine.setMode(.following)
        let north = try #require(engine.update(input(northBend, distance: 0, speed: 12, time: 30)))
        expectUsable(north)
        #expect(angleDifference(north.bearing, 0) < 25)
        let turned = try #require(engine.update(input(northBend, distance: 2.4, speed: 12, time: 30.2)))
        expectUsable(turned)
        #expect(angleDifference(north.bearing, turned.bearing) < 12)
    }

    @Test func routeCorridorFitsPortraitLandscapeAndExpandedPanels() {
        let origin = point()
        var straight = CameraIntent(target: point(north: 110), zoom: 18, pitch: 42,
            bearing: 0, padding: .navigation, followCoordinate: origin, anchorFraction: 0.72)
        straight.framingCoordinates = [origin, point(north: 110)]
        var turning = straight
        turning.framingCoordinates = [origin, point(east: 260, north: 50),
                                     point(east: -240, north: 80), point(north: 110)]
        let viewports: [(width: Double, height: Double, padding: CameraPadding)] = [
            (390, 844, .init(top: 190, left: 24, bottom: 240, right: 24)),
            (844, 390, .init(top: 70, left: 48, bottom: 140, right: 24)),
            (390, 844, .init(top: 190, left: 24, bottom: 520, right: 24)),
            (390, 844, .init(top: 250, left: 24, bottom: 650, right: 24))
        ]
        for viewport in viewports {
            let fitted = turning.fittingViewport(viewport.padding,
                width: viewport.width, height: viewport.height)
            expectUsable(fitted)
            #expect(fitted.target == origin)
            #expect(fitted.padding.bottom >= viewport.padding.bottom)
            #expect(fitted.padding.top + fitted.padding.bottom < viewport.height)
            #expect(fitted.padding.left + fitted.padding.right < viewport.width)
            #expect(fitted.zoom <= turning.zoom)
            let arrowY = (fitted.padding.top + viewport.height - fitted.padding.bottom) / 2
            #expect(arrowY >= fitted.padding.top)
            #expect(arrowY < viewport.height - viewport.padding.bottom,
                    "Strzałka musi pozostać nad dolnym panelem")
        }
        let padding = viewports[0].padding
        let straightPortrait = straight.fittingViewport(padding, width: 390, height: 844)
        let turningPortrait = turning.fittingViewport(padding, width: 390, height: 844)
        #expect(turningPortrait.zoom < straightPortrait.zoom - 0.5,
                "Boczny przebieg skrętu musi wpłynąć na skalę, nawet przy identycznym punkcie końcowym")
        let turningWide = turning.fittingViewport(padding, width: 780, height: 844)
        #expect(turningWide.zoom > turningPortrait.zoom,
                "Kadrowanie musi uwzględniać rzeczywistą szerokość mapy")
    }

    @Test func postViewportRenderingStaysContinuousWithSparseFixesAndPanelChanges() {
        func signedAngle(_ start: Double, _ end: Double) -> Double {
            var value = (end - start).truncatingRemainder(dividingBy: 360)
            if value > 180 { value -= 360 }
            if value < -180 { value += 360 }
            return value
        }
        func run(framesPerSecond: Int) -> CameraIntent {
            let origin = point()
            var rendered = CameraIntent(target: origin, zoom: 16, pitch: 40, bearing: 350,
                padding: .init(top: 190, left: 24, bottom: 240, right: 24),
                followCoordinate: origin, anchorFraction: 0.68)
            var filter = NavigationCameraRenderSmoother()
            filter.reset(to: rendered, timestamp: 0)
            var desired = rendered
            var lastSample = -1
            var lateSampleRotation = 0.0
            var reversed = false
            for frame in 1...(framesPerSecond * 12) {
                let time = Double(frame) / Double(framesPerSecond)
                let sample = frame / framesPerSecond
                let panelChanged = sample != lastSample && (sample == 7 || sample == 10)
                if sample != lastSample {
                    let turn = sample < 6 ? Double(sample) * 18 : 108 - Double(sample - 6) * 18
                    desired.bearing = (350 + turn + 360).truncatingRemainder(dividingBy: 360)
                    desired.zoom = 18
                    desired.pitch = sample < 6 ? 54 : 24
                    desired.framingCoordinates = [origin,
                        point(east: sample < 6 ? 250 : 20, north: 180)]
                    let padding = CameraPadding(top: 190, left: 24,
                                                bottom: (7..<10).contains(sample) ? 520 : 240, right: 24)
                    desired = desired.fittingViewport(padding, width: 390, height: 844)
                    lastSample = sample
                }
                // GPS supplies perspective only once a second; the puck still
                // advances independently in every rendered frame.
                desired.target = point(north: time * 10)
                desired.followCoordinate = desired.target
                let next = filter.step(desired, timestamp: time, smoothPadding: !panelChanged)
                expectUsable(next)
                let headingStep = signedAngle(rendered.bearing, next.bearing)
                #expect(abs(headingStep) <= 55 / Double(framesPerSecond) + 1e-8)
                #expect(abs(next.zoom - rendered.zoom) <= 0.45 / Double(framesPerSecond) + 1e-8,
                        "Ograniczenie zoomu musi obowiązywać także po dopasowaniu geometrii i panelu")
                #expect(abs(next.pitch - rendered.pitch) <= 14 / Double(framesPerSecond) + 1e-8)
                #expect(next.target == desired.target && next.followCoordinate == desired.followCoordinate)
                #expect(next.framingCoordinates == desired.framingCoordinates)
                #expect(next.animationDuration == 0)
                if time > 2.86 && time < 2.99 { lateSampleRotation += abs(headingStep) }
                if time > 8 && headingStep < -0.001 { reversed = true }
                if panelChanged {
                    #expect(next.padding == desired.padding,
                            "Nowy obszar zasłonięcia musi obowiązywać w tej samej klatce")
                }
                rendered = next
            }
            #expect(lateSampleRotation > 0.1,
                    "Obrót nie może zatrzymywać się po 0,85 s w oczekiwaniu na kolejną próbkę GPS")
            #expect(reversed, "Kamera musi płynnie podjąć przeciwny kierunek zakrętu")

            var changed = desired
            changed.bearing = 180
            changed.zoom = 18
            let duplicate = filter.step(changed, timestamp: 12)
            let old = filter.step(changed, timestamp: 11)
            #expect(duplicate.bearing == rendered.bearing && old.bearing == rendered.bearing)
            #expect(duplicate.zoom == rendered.zoom && old.zoom == rendered.zoom)
            let resumed = filter.step(changed, timestamp: 120)
            #expect(angleDifference(resumed.bearing, rendered.bearing) <= 55 * 0.05 + 1e-8)
            #expect(abs(resumed.zoom - rendered.zoom) <= 0.45 * 0.05 + 1e-8,
                    "Powrót z tła nie może odtworzyć całej zaległej animacji")
            return rendered
        }
        let thirty = run(framesPerSecond: 30)
        let sixty = run(framesPerSecond: 60)
        // The difference may contain one frame of input sampling, but must not
        // accumulate into a different camera trajectory at the lower frame rate.
        #expect(angleDifference(thirty.bearing, sixty.bearing) < 0.6)
        #expect(abs(thirty.zoom - sixty.zoom) < 0.02)
        #expect(abs(thirty.pitch - sixty.pitch) < 0.02)

        var north = NavigationCameraRenderSmoother()
        var actual = CameraIntent(target: point(), zoom: 16, pitch: 40, bearing: 359,
                                  padding: .navigation)
        north.reset(to: actual, timestamp: 0)
        actual.bearing = 1
        let crossing = north.step(actual, timestamp: 1.0 / 60)
        #expect(signedAngle(359, crossing.bearing) > 0)
        #expect(signedAngle(359, crossing.bearing) < 0.1,
                "Przejście przez północ musi wybrać krótki i łagodny obrót")

        for fps in [30, 60] {
            var handoff = NavigationCameraFollowHandoff()
            let center = point(north: 100)
            let puckAtCompletion = point(north: 120)
            let ordinary = handoff.coordinate(following: puckAtCompletion, timestamp: 10)
            #expect(ordinary == puckAtCompletion,
                    "Zwykłe śledzenie nie może dodawać opóźnienia pozycji")
            handoff.begin(from: center, following: puckAtCompletion, timestamp: 10)
            let first = handoff.coordinate(following: puckAtCompletion, timestamp: 10)
            #expect(first.distance(to: center) < 0.001,
                    "Przejęcie po centrowaniu musi zacząć się od rzeczywistego kadru")
            var previousError = first.distance(to: puckAtCompletion)
            var latest = first
            for frame in 1...(fps * 3 / 5) {
                let elapsed = Double(frame) / Double(fps)
                let puck = point(east: elapsed * 8, north: 120 + elapsed * 20)
                let next = handoff.coordinate(following: puck, timestamp: 10 + elapsed)
                let error = next.distance(to: puck)
                #expect(error <= previousError + 0.001,
                        "Pozostały błąd centrowania powinien wygasać bez oscylacji")
                #expect(abs(next.longitude - puck.longitude) < 1e-10,
                        "Nowy ruch poprzeczny znacznika nie może oczekiwać na koniec korekty")
                if frame == 1 {
                    #expect(next.distance(to: first) < 1,
                            "Pierwsza klatka nie może wykonać skoku o całe zaległe 20 metrów")
                }
                previousError = error
                latest = next
                if elapsed >= 0.5 { #expect(next == puck) }
            }
            #expect(!handoff.isActive)
            let live = point(east: 8, north: 150)
            let following = handoff.coordinate(following: live, timestamp: 11)
            #expect(following == live && latest.distance(to: live) > 1)

            handoff.begin(from: center, following: live, timestamp: 12)
            handoff.cancel() // Gesture, a new route, or a panel boundary change.
            let cancelled = handoff.coordinate(following: live, timestamp: 12.1)
            #expect(cancelled == live && !handoff.isActive)
        }

        var dateline = NavigationCameraFollowHandoff()
        let west = Coordinate(latitude: 52, longitude: 179.9998)
        let east = Coordinate(latitude: 52, longitude: -179.9998)
        dateline.begin(from: west, following: east, timestamp: 20)
        let datelineStart = dateline.coordinate(following: east, timestamp: 20)
        #expect(datelineStart.distance(to: west) < 0.001)
        let middle = dateline.coordinate(following: east, timestamp: 20.25)
        #expect(middle.distance(to: east) < west.distance(to: east))
        #expect(abs(middle.longitude) > 179.99,
                "Korekta przy południku 180° nie może przejechać przez środek świata")
        let stale = dateline.coordinate(following: east, timestamp: 20.1)
        #expect(stale == middle)
        let resumed = dateline.coordinate(following: east, timestamp: 25)
        #expect(resumed == east && !dateline.isActive)

#if os(iOS)
        let expanded = CameraPadding(top: 190, left: 24, bottom: 520, right: 24)
        let peek = CameraPadding(top: 190, left: 24, bottom: 240, right: 24)
        let medium = CameraPadding(top: 190, left: 24, bottom: 380, right: 24)
        for fps in [30, 60] {
            var viewport = NavigationCameraViewportTransition()
            viewport.reset(to: expanded, timestamp: 0)
            let collapseStart = viewport.step(peek, timestamp: 1,
                isTrackingFinger: false, reduceMotion: false)
            #expect(collapseStart == expanded && viewport.isAnimating,
                    "Zwinięcie nie może od razu odsłonić obszaru nadal zakrytego panelem")
            var moving = collapseStart
            for frame in 1...(fps / 5) {
                moving = viewport.step(peek, timestamp: 1 + Double(frame) / Double(fps),
                    isTrackingFinger: false, reduceMotion: false)
                #expect(moving.bottom < expanded.bottom && moving.bottom > peek.bottom)
            }
            #expect(moving.bottom < 300,
                    "Powtarzanie celu, także po próbce GPS, nie może restartować sprężyny panelu")
            let retargeted = viewport.step(medium, timestamp: 1.2,
                isTrackingFinger: false, reduceMotion: false)
            #expect(abs(retargeted.bottom - moving.bottom) < 0.001,
                    "Zmiana kierunku panelu musi zachować ciągłość kadru")
            let finger = viewport.step(expanded, timestamp: 1.21,
                isTrackingFinger: true, reduceMotion: false)
            #expect(finger == expanded && !viewport.isAnimating,
                    "Przeciąganie palcem nie może odziedziczyć opóźnienia animacji")
            let released = viewport.step(peek, timestamp: 1.22,
                isTrackingFinger: false, reduceMotion: false)
            #expect(released == finger && viewport.isAnimating,
                    "Dosiadanie po puszczeniu musi zacząć się od ostatniej pozycji palca")
            let reducedMotion = viewport.step(medium, timestamp: 1.23,
                isTrackingFinger: false, reduceMotion: true)
            #expect(reducedMotion == medium && !viewport.isAnimating,
                    "Redukcja ruchu musi wyłączać także animację obszaru kamery")
        }
#endif
    }

    private struct DrivingScenario {
        let name: String
        let coordinates: [Coordinate]
        let turnIndex: Int?
        let turnAngle: Double?
        var roundabout = false
        var exitIndex: Int? = nil
    }

    private func point(east: Double = 0, north: Double = 0) -> Coordinate {
        Coordinate(latitude: 52 + north / 111_320,
                   longitude: 21 + east / (111_320 * cos(52 * .pi / 180)))
    }

    private func geometry(_ coordinates: [Coordinate]) -> RouteProgressGeometry {
        let length = RouteProgressGeometry(coordinates: coordinates).length
        return RouteProgressGeometry(NavigationRoute(coordinates: coordinates, distance: length,
            expectedTravelTime: length / 11, maneuvers: []))
    }

    private func input(_ geometry: RouteProgressGeometry, distance: Double, speed: Double,
                       time: TimeInterval, course: Double? = nil,
                       maneuverDistance: Double? = nil, angle: Double? = nil,
                       roundabout: Bool = false, state: NavigationCameraState = .followNavigation,
                       maneuverIndex: Int? = nil,
                       followingManeuverDistance: Double? = nil) -> NavigationCameraInput {
        NavigationCameraInput(matchedCoordinate: geometry.coordinate(at: distance) ?? point(),
            routeDistance: distance, speed: speed, course: course,
            distanceToNextManeuver: maneuverDistance, maneuverAngle: angle,
            isRoundabout: roundabout, isMotorwayExit: false, viewportPadding: .navigation,
            timestamp: time, cameraState: state, maneuverIndex: maneuverIndex,
            followingManeuverDistance: followingManeuverDistance)
    }

    private func angleDifference(_ first: Double, _ second: Double) -> Double {
        let delta = (second - first + 540).truncatingRemainder(dividingBy: 360) - 180
        return abs(delta)
    }

    private func expectUsable(_ intent: CameraIntent) {
        #expect(intent.target.latitude.isFinite && intent.target.longitude.isFinite)
        #expect(intent.zoom.isFinite && (10...20).contains(intent.zoom))
        #expect(intent.pitch.isFinite && (0...60).contains(intent.pitch))
        #expect(intent.bearing.isFinite && (0..<360).contains(intent.bearing))
        #expect(intent.anchorFraction.isFinite && (0.6...0.84).contains(intent.anchorFraction))
        #expect([intent.padding.top, intent.padding.left, intent.padding.bottom,
                 intent.padding.right].allSatisfy { $0.isFinite && $0 >= 0 })
    }
}
