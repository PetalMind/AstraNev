import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

extension ContentView {
    var maneuverCard: some View {
        let maneuver = engine.state.progress?.nextManeuver
        let maneuverDistance = engine.state.progress?.distanceToNextManeuver ?? .infinity
        let guidanceDistance = maneuverDistance.isFinite
            ? maneuverDistance
            : (engine.state.transportMode == .parkRide
                ? (parkRideCarDistanceToTransfer ?? .infinity)
                : (engine.state.progress?.remainingDistance ?? .infinity))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: maneuver?.iconName
                      ?? (engine.state.transportMode == .parkRide ? "parkingsign.circle.fill" : "arrow.up"))
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.state.status == .rerouting
                         ? "Przeliczanie trasy…"
                         : (guidanceDistance <= 25 ? "TERAZ" : distance(guidanceDistance)))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())

                    Text(maneuver?.displayInstruction
                         ?? (engine.state.transportMode == .parkRide
                             ? "Jedź do parkingu P+R" : "Kontynuuj do celu"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let streetLine = maneuver?.streetLine {
                        Text(streetLine)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    if guidanceDistance.isFinite, guidanceDistance <= 25 {
                        Text(distance(guidanceDistance))
                            .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    laneGuidance
                }
            }

            if engine.state.transportMode == .car, let incident = nextRouteTrafficIncident {
                HStack(spacing: 7) {
                    Image(systemName: incident.isRoadClosure ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(incident.isRoadClosure ? Color.red : Color.orange)
                    Text("\(incident.category.mapLabel) · za \(distance(max(0, (incident.distanceAlongRoute ?? 0) - (engine.state.progress?.traveledDistance ?? 0))))")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if let delay = incident.delaySeconds, delay > 0 {
                        Text("+\(max(1, Int((Double(delay) / 60).rounded()))) min")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
            }

            if let maneuver = engine.state.progress?.nextManeuver,
               let exitNumber = maneuver.exitNumber {
                HStack(spacing: 6) {
                    Image(systemName: maneuver.iconName)
                    Text("Zjazd \(exitNumber)")
                    if let road = maneuver.exitRoad { Text("· \(road)") }
                    if let toward = maneuver.exitToward { Text("· kierunek \(toward)") }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
            }

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .modifier(NavigationGlassSurface(radius: 21))
        .accessibilityElement(children: .combine)
    }

    var nextRouteTrafficIncident: TrafficIncident? {
        guard engine.state.route != nil else { return nil }
        let traveledDistance = engine.state.progress?.traveledDistance ?? 0
        return (engine.state.traffic?.incidents ?? [])
            .filter { incident in
                guard let distance = incident.distanceAlongRoute else { return false }
                return distance > traveledDistance && distance <= traveledDistance + 12_000
            }
            .min { ($0.distanceAlongRoute ?? .infinity) < ($1.distanceAlongRoute ?? .infinity) }
    }

    var transitNavigationHeader: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            transitNavigationHeaderContent(at: context.date)
        }
    }

    func transitNavigationHeaderContent(at date: Date) -> some View {
        let leg = activeTransitLeg
        let tracking = leg.flatMap { transitProgress(for: $0) }
        let isWalking = leg?.mode.uppercased() == "WALK"
        let liveNextStop = liveTransitTripDetails?.tripID == leg?.tripID
            ? liveTransitTripDetails?.nextStops.first { $0.arrival > date } : nil
        let liveTrackedStop = tracking?.nextStop.flatMap { trackedStop in
            liveTransitTripDetails?.tripID == leg?.tripID
                ? liveTransitTripDetails?.nextStops.first(where: { $0.stopID == trackedStop.stopID }) : nil
        }
        let nextStop = tracking?.nextStop ?? liveNextStop ?? leg?.transitStops.first { $0.arrival > date }
        let waitingForDeparture = !isWalking && tracking?.isOnVehicle != true && (leg?.departure ?? date) > date
        let walkingMinutes = tracking.map { Int(ceil($0.distanceToLegEnd / 1.25 / 60)) }
        let remainingMinutes = isWalking
            ? (walkingMinutes ?? max(0, Int(ceil((leg?.arrival ?? date).timeIntervalSince(date) / 60))))
            : max(0, Int(ceil((leg?.arrival ?? date).timeIntervalSince(date) / 60)))
        let title: String
        if isWalking {
            title = "Idź do \(leg?.to ?? "przystanku")"
        } else if waitingForDeparture {
            title = "Wsiądź na \(leg?.from ?? "przystanku")"
        } else if tracking?.isOnVehicle == true, tracking?.stopsUntilAlighting == 1 {
            title = "Wysiadaj na \(leg?.to ?? "następnym przystanku")"
        } else {
            title = "Następny · \(nextStop?.name ?? leg?.to ?? "przystanek")"
        }
        let eta: String
        if isWalking {
            eta = "\(remainingMinutes) min"
        } else if waitingForDeparture {
            eta = transitETA(leg?.departure ?? date, now: date)
        } else if let liveTrackedStop {
            eta = transitETA(liveTrackedStop.arrival, now: date)
        } else if let nextStop {
            eta = transitETA(nextStop.arrival, now: date)
        } else {
            eta = "—"
        }

        let subtitle: String
        if isWalking {
            subtitle = "Pieszo · około \(remainingMinutes) min"
        } else if tracking?.isOnVehicle == true {
            subtitle = "Linia \(leg?.line ?? "MPK") · wysiadka: \(leg?.to ?? "cel") · \(tracking?.stopsUntilAlighting ?? 0) przyst."
        } else {
            subtitle = "Linia \(leg?.line ?? "MPK") · kierunek \(leg?.to ?? "")"
        }

        return HStack(spacing: 12) {
            if let leg, !isWalking {
                Text(leg.line ?? "MPK")
                    .font(.headline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 44, minHeight: 42)
                    .background(mapTransitColor(leg.lineColorHex ?? 0x2867B2), in: RoundedRectangle(cornerRadius: 13))
            } else {
                Image(systemName: "figure.walk")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 42)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 13))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(eta)
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(isWalking ? "do przystanku" : waitingForDeparture ? "do odjazdu" : "do przystanku")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .modifier(NavigationGlassSurface(radius: 21))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    var laneGuidance: some View {
        if let lanes = engine.state.progress?.nextManeuver?.lanes, !lanes.isEmpty {
            HStack(spacing: 4) {
                ForEach(lanes) { lane in
                    Image(systemName: laneSymbol(lane.indications))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(lane.valid ? Color.accentColor : Color.secondary.opacity(0.55))
                        .frame(width: 20, height: 30)
                        .background(lane.valid ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .accessibilityLabel("Wskazówki wyboru pasa")
        }
    }

    func laneSymbol(_ indications: [String]) -> String {
        let value = indications.joined(separator: " ").lowercased()
        if value.contains("uturn") { return "arrow.uturn.left" }
        if value.contains("left") && value.contains("right") { return "arrow.up.left.and.arrow.up.right" }
        if value.contains("left") { return "arrow.turn.up.left" }
        if value.contains("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }

    var destinationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 34, height: 4)
                .frame(maxWidth: .infinity)
            HStack {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Planowanie trasy")
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Button(destinationExpanded ? "Zwiń" : "Rozwiń",
                       systemImage: destinationExpanded ? "chevron.down" : "chevron.up") {
                    withAnimation(.easeInOut(duration: 0.25)) { destinationExpanded.toggle() }
                }
                .labelStyle(.iconOnly)
                Button("Zamknij", systemImage: "xmark") { engine.stop() }
                    .labelStyle(.iconOnly)
            }
            routeEndpointFields
            Button {
                Task { await engine.planRoute() }
            } label: {
                Label("Wyznacz trasę", systemImage: "arrow.triangle.turn.up.right.diamond")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if destinationExpanded, let destination = engine.state.destination {
                Divider()
                HStack(spacing: 14) {
                    Button("Zapisz", systemImage: "heart") {
                        isSavingPlace = true
                        favoriteName = destination.name
                    }
                    .buttonStyle(.bordered)
                    if let url = URL(string: "https://maps.apple.com/?ll=\(destination.coordinate.latitude),\(destination.coordinate.longitude)") {
                        ShareLink(item: url) { Label("Udostępnij", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.bordered)
                    }
                }
                if isSavingPlace {
                    HStack {
                        TextField("Nazwa miejsca", text: $favoriteName)
                        Menu("Zapisz jako") {
                            ForEach(PlaceKind.allCases, id: \.self) { kind in
                                Button(kind.title) { saveCurrentPlace(as: kind); isSavingPlace = false }
                            }
                        }
                    }
                }
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NavigationGlassSurface(radius: 26))
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height < -40 { destinationExpanded = true }
            if value.translation.height > 40 { destinationExpanded = false }
        })
    }

    var routeCalculatingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if engine.state.destination != nil {
                transportSelector
            }
            HStack(spacing: 12) {
                ProgressView()
                Text("Wyznaczanie trasy…")
                    .font(.headline)
                    .contentTransition(.opacity)
                Spacer()
                Button("Anuluj", systemImage: "xmark") { engine.stop() }
                    .labelStyle(.iconOnly)
            }
        }
        .padding(14)
        .modifier(NavigationGlassSurface(radius: 26))
    }

    var routePreviewCard: some View {
#if os(iOS)
        routePlanningSheet(maxHeight: 560, bottomInset: 0)
#else
        desktopRoutePreviewCard
#endif
    }

    var desktopRoutePreviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    routePreviewExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(routePreviewExpanded ? "Zwiń szczegóły" : "Szczegóły trasy")
                    Spacer()
                    Image(systemName: routePreviewExpanded ? "chevron.down" : "chevron.up")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(routePreviewExpanded ? "Zwiń szczegóły trasy" : "Rozwiń szczegóły trasy")

            routeEndpointFields
            HStack {
                Spacer()
                Button(action: toggleDestinationFavorite) {
                    Image(systemName: isDestinationFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isDestinationFavorite ? Color.red : Color.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                        .scaleEffect(favoritePulseScale)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isDestinationFavorite ? "Usuń cel z ulubionych" : "Zapisz cel w ulubionych")
            }

            if isRouteOriginAwayFromUser, let origin = engine.state.routeOrigin {
                VStack(alignment: .leading, spacing: 8) {
                    if let location = engine.state.location {
                        Label("Start trasy: \(distance(origin.coordinate.distance(to: location.coordinate))) od Ciebie",
                              systemImage: "location.north.line")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Start trasy ustawiono poza bieżącą lokalizacją",
                              systemImage: "location.north.line")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await engine.setRouteOrigin(nil) }
                    } label: {
                        Label("Użyj mojej lokalizacji jako start", systemImage: "location.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 2)
            }

            transportSelector
            if engine.state.transportMode == .transit || engine.state.transportMode == .parkRide {
                journeyTimeControl
            }

            if let route = engine.state.route {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(time(route.expectedTravelTime))
                            .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text("PODRÓŻ")
                            .font(.caption2.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(distance(route.distance))
                            .font(.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                        Text("TRASA")
                            .font(.caption2.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 7) {
                    ForEach(Array(engine.state.routeOptions.enumerated()), id: \.element.id) { item in
                        routeOption(item.element, index: item.offset + 1,
                                    selectedRoute: route, isSelected: item.element.id == route.id)
                    }
                }

                if engine.state.transportMode == .transit, let journey = route.journey {
                    let transitLegs = journey.legs.filter { $0.mode != "WALK" }
                    if let firstRide = transitLegs.first {
                        let rideDuration = transitLegs.reduce(0.0) {
                            $0 + $1.arrival.timeIntervalSince($1.departure)
                        }
                        HStack(spacing: 8) {
                            Text(firstRide.line ?? "MPK")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 5)
                                .background(mapTransitColor(firstRide.lineColorHex ?? 0x2867B2), in: RoundedRectangle(cornerRadius: 7))
                            Text(transitLegs.map { $0.line ?? "MPK" }.joined(separator: " → "))
                                .font(.caption.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            if let delay = displayedTransitDelay(for: firstRide), abs(delay) >= 30 {
                                HStack(spacing: 4) {
                                    Text(delayLabel(TimeInterval(delay)))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(transitDelayColor(delay))
                                    Text(transitTimeSourceLabel(for: firstRide, in: journey))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            } else if firstRide.realTime || hasLiveTransitUpdate(for: firstRide) {
                                Text(transitTimeSourceLabel(for: firstRide, in: journey))
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("wg rozkładu")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 5) {
                            Text("Wsiadasz \(firstRide.departure.formatted(date: .omitted, time: .shortened))")
                            Text("·")
                            Text("Przyjazd \(journey.arrival.formatted(date: .omitted, time: .shortened))")
                        }
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Text("Pojazdami \(transitMetricTime(rideDuration)) · pieszo \(transitMetricTime(journey.walkingDuration)) · czekanie \(transitMetricTime(journey.waitingDuration)) · przesiadki: \(journey.transferCount)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        Button {
                            Task { await engine.loadLaterTransitConnections(after: firstRide.departure) }
                        } label: {
                            HStack(spacing: 7) {
                                if engine.state.isLoadingLaterTransitRoutes {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "clock.arrow.circlepath")
                                }
                                Text(engine.state.isLoadingLaterTransitRoutes
                                     ? "Szukam późniejszych połączeń…"
                                     : "Pokaż późniejsze połączenia")
                            }
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: 38)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(engine.state.isLoadingLaterTransitRoutes
                                  || engine.state.transitPlanningPhase == .enrichingGeometry)
                    }
                    if engine.state.transitPlanningPhase == .enrichingGeometry {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Znaleziono połączenia. Uzupełniam przebieg dojść pieszych…")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } else if journey.legs.contains(where: {
                        $0.mode == "WALK" && $0.walkingTimeIsApproximate
                    }) {
                        Label("Czasy dojść są szacunkowe.", systemImage: "info.circle")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if journey.legs.contains(where: {
                        $0.mode == "WALK" && !$0.hasResolvedWalkingGeometry
                    }) {
                        Label("Przebieg dojść jest pokazany orientacyjnie.", systemImage: "info.circle")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if engine.state.didSearchLaterTransitRoutes && engine.state.laterTransitRoutes.isEmpty {
                    Text("Nie znaleziono późniejszych połączeń w dostępnym rozkładzie.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !engine.state.laterTransitRoutes.isEmpty {
                    laterTransitConnections
                }

                if routePreviewExpanded {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 15) {
                            routeEndpoints
                            waypointDetails
                            if !route.chargingStops.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("Ładowanie po drodze")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Szacowany czas postojów: \(Int((route.chargingDuration / 60).rounded())) min")
                                        .font(.caption).foregroundStyle(.secondary)
                                    ForEach(route.chargingStops) { stop in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(stop.destination.name).font(.caption.weight(.medium))
                                            Text("\(stop.connectorTypes.joined(separator: ", ")) · do \(Int(stop.maximumPowerKW.rounded())) kW · postój \(Int((stop.estimatedChargingTime / 60).rounded())) min")
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Text(stop.availabilityKnown ? "Status: działająca według OpenStreetMap" : "Dostępność ładowarki nieznana")
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Text(stop.publicAccess == true ? "Dostęp publiczny według OpenStreetMap" : "Dostęp publiczny niepotwierdzony")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Opcje trasy")
                                    .font(.subheadline.weight(.semibold))
                                routePreferenceToggle("Unikaj autostrad", keyPath: \.avoidHighways)
                                routePreferenceToggle("Unikaj dróg płatnych", keyPath: \.avoidTolls)
                                routePreferenceToggle("Unikaj promów", keyPath: \.avoidFerries)
                            }

                            if let journey = route.journey {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("Połączenie")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Odjazd \(journey.departure.formatted(date: .omitted, time: .shortened)) · Przyjazd \(journey.arrival.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                    Text(transitRealtimeStatus(for: journey))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if journey.alertsFeedAvailable && journey.alerts.isEmpty {
                                        Text("Brak aktywnych komunikatów dla tej trasy")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    } else if !journey.alertsFeedAvailable {
                                        Text("Komunikaty na trasie niedostępne")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let attribution = journey.railwayScheduleAttribution {
                                        Text(attribution)
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if journey.scheduleIsCached {
                                        Text("Rozkład pobrany z pamięci urządzenia")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    ForEach(Array(journey.alerts.enumerated()), id: \.offset) { _, alert in
                                        Label(alert, systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                    ForEach(journey.legs) { leg in
                                        HStack(alignment: .top, spacing: 9) {
                                            Text(leg.departure.formatted(date: .omitted, time: .shortened))
                                                .monospacedDigit()
                                            VStack(alignment: .leading, spacing: 2) {
                                                let legTitle = leg.mode == "WALK"
                                                    ? (leg.isTransfer ? "Przesiadka pieszo" : "Dojście pieszo")
                                                    : (leg.line ?? leg.mode)
                                                Text("\(legTitle) · \(leg.from) → \(leg.to)")
                                                if let delay = displayedTransitDelay(for: leg), abs(delay) >= 30 {
                                                    HStack(spacing: 4) {
                                                        Text(delayLabel(TimeInterval(delay)))
                                                            .foregroundStyle(transitDelayColor(delay))
                                                        Text(transitTimeSourceLabel(for: leg, in: journey))
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    .font(.caption2)
                                                } else if hasLiveTransitUpdate(for: leg) {
                                                    Text(transitTimeSourceLabel(for: leg, in: journey))
                                                        .font(.caption2).foregroundStyle(.secondary)
                                                } else if leg.realTime {
                                                    Text(transitTimeSourceLabel(for: leg, in: journey))
                                                        .font(.caption2).foregroundStyle(.secondary)
                                                } else if leg.mode != "WALK" {
                                                    Text("wg rozkładu")
                                                        .font(.caption2).foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        .font(.caption)
                                    }
                                }
                            }

                            if engine.state.transportMode == .car {
                                Button {
                                    appRouter.present(.trafficDetails)
                                } label: {
                                    Label("Szczegóły ruchu", systemImage: "car.side")
                                        .font(.subheadline.weight(.medium))
                                }
                                .buttonStyle(.plain)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                        isSavingPlace.toggle()
                                    }
                                    if !isSavingPlace { favoriteName = "" }
                                } label: {
                                    Label(isSavingPlace ? "Zamknij zapis" : "Zapisz miejsce",
                                          systemImage: isSavingPlace ? "checkmark" : "star")
                                        .font(.subheadline.weight(.medium))
                                }
                                .buttonStyle(.plain)

                                if isSavingPlace {
                                    HStack(spacing: 8) {
                                        TextField("Nazwa miejsca", text: $favoriteName)
                                            .textFieldStyle(.roundedBorder)
                                            .submitLabel(.done)
                                        Menu {
                                            ForEach(PlaceKind.allCases, id: \.self) { kind in
                                                Button(kind.title, systemImage: kind == .home ? "house" : kind == .work ? "briefcase" : "star") {
                                                    saveCurrentPlace(as: kind)
                                                }
                                            }
                                        } label: {
                                            Label("Zapisz jako", systemImage: "checkmark")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                    .frame(height: 240)
                    .scrollIndicators(.hidden)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if engine.state.transportMode != .transit {
                    beginRouteButton
                }
            } else if engine.state.status == .routeCalculating {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(engine.state.transportMode == .transit
                         ? (engine.state.transitPlanningPhase == .loadingSchedule
                            ? "Aktualizuję rozkłady…" : "Szukam połączeń…")
                         : "Wyznaczanie trasy…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                HStack {
                    Text(engine.state.errorMessage ?? "Nie udało się wyznaczyć trasy.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Spróbuj ponownie") { Task { await engine.planRoute() } }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 7)
        .padding(.bottom, 11)
        .modifier(NavigationGlassSurface(radius: 26))
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height < -35 {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { routePreviewExpanded = true }
            } else if value.translation.height > 35 {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { routePreviewExpanded = false }
            }
        })
    }

    var beginRouteButton: some View {
        Button {
            if isRouteOriginAwayFromUser {
                navigateToRouteOrigin()
            } else {
                engine.begin()
            }
        } label: {
            Label(isRouteOriginAwayFromUser ? "Nawiguj do punktu startowego" : "Rozpocznij",
                  systemImage: isRouteOriginAwayFromUser ? "location.magnifyingglass" :
                    (engine.state.transportMode == .transit ? "tram.fill" : "location.fill"))
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(engine.state.status != .routePreview
                  || engine.state.transitPlanningPhase == .enrichingGeometry)
        .opacity(engine.state.status == .routePreview
                 && engine.state.transitPlanningPhase != .enrichingGeometry ? 1 : 0.55)
    }

    func navigateToRouteOrigin() {
        guard let point = engine.state.routeOrigin, !point.isCurrentLocation else { return }
        let originDestination = point.destination
        engine.state.routeOrigin = nil
        engine.selectDestination(originDestination)
        Task { await engine.planRoute() }
    }

    var transportSelector: some View {
        HStack(spacing: 5) {
            ForEach(TransportMode.allCases) { mode in
                Button {
                    Task { await engine.selectTransportMode(mode) }
                } label: {
                    Group {
                        if engine.state.transportMode == mode {
                            HStack(spacing: 8) {
                                Image(systemName: mode.symbol)
                                    .font(.system(size: 16, weight: .semibold))
                                Text(mode.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        } else {
                            VStack(spacing: 3) {
                                Image(systemName: mode.symbol)
                                    .font(.system(size: 15, weight: .medium))
                                Text(compactTitle(for: mode))
                                    .font(.system(size: 9, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                        }
                    }
                    .foregroundStyle(engine.state.transportMode == mode ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: engine.state.transportMode == mode ? 132 : .infinity)
                    .layoutPriority(engine.state.transportMode == mode ? 1 : 0)
                    .frame(minHeight: 48)
                    .padding(.horizontal, engine.state.transportMode == mode ? 5 : 0)
                    .background {
                        if engine.state.transportMode == mode {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1)
                                }
                                .matchedGeometryEffect(id: "selected-transport", in: transportSelectionNamespace)
                        } else {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.primary.opacity(0.035))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(engine.state.transportMode == mode ? .isSelected : [])
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: engine.state.transportMode)
    }

    var journeyTimeControl: some View {
        HStack(spacing: 8) {
            Menu {
                Button { chooseJourneyTimeMode(.now) } label: {
                    Label("Teraz", systemImage: engine.state.journeyTimeMode == .now ? "checkmark" : "clock")
                }
                Button { chooseJourneyTimeMode(.departAt) } label: {
                    Label("Wyjazd o…", systemImage: engine.state.journeyTimeMode == .departAt ? "checkmark" : "arrow.up.right")
                }
                if engine.state.transportMode == .transit {
                    Button { chooseJourneyTimeMode(.arriveBy) } label: {
                        Label("Przyjazd na…", systemImage: engine.state.journeyTimeMode == .arriveBy ? "checkmark" : "mappin")
                    }
                }
            } label: {
                Label(journeyTimeControlTitle, systemImage: "clock")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 11)
                    .frame(minHeight: 36)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .accessibilityLabel("Kiedy chcesz jechać")
            .disabled(engine.state.status != .routePreview
                      || engine.state.transitPlanningPhase == .enrichingGeometry)

            if engine.state.journeyTimeMode != .now {
                DatePicker(
                    engine.state.journeyTimeMode == .departAt ? "Godzina wyjazdu" : "Godzina przyjazdu",
                    selection: Binding(
                        get: { engine.state.journeyTargetTime },
                        set: { engine.setJourneyTargetTime($0) }),
                    in: Date()...Date().addingTimeInterval(18 * 60 * 60),
                    displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .accessibilityLabel(engine.state.journeyTimeMode == .departAt
                                        ? "Godzina wyjazdu" : "Godzina przyjazdu")
                    .disabled(engine.state.status != .routePreview
                              || engine.state.transitPlanningPhase == .enrichingGeometry)

                Button {
                    Task { await engine.planRoute() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Przelicz połączenia")
                .disabled(engine.state.status != .routePreview
                          || engine.state.transitPlanningPhase == .enrichingGeometry)
            }
            Spacer(minLength: 0)
        }
    }

    var journeyTimeControlTitle: String {
        switch engine.state.journeyTimeMode {
        case .now: "Teraz"
        case .departAt: "Wyjazd o"
        case .arriveBy: "Przyjazd na"
        }
    }

    func chooseJourneyTimeMode(_ mode: JourneyTimeMode) {
        engine.setJourneyTimeMode(mode)
        if mode == .now {
            Task { await engine.planRoute() }
        }
    }

    var laterTransitConnections: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Późniejsze połączenia")
                .font(.subheadline.weight(.semibold))
            ForEach(engine.state.laterTransitRoutes) { route in
                if let journey = route.journey,
                   let firstRide = journey.legs.first(where: { $0.mode != "WALK" }) {
                    Button {
                        engine.selectLaterTransitConnection(route)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(firstRide.departure.formatted(date: .omitted, time: .shortened))  ·  \(time(route.expectedTravelTime))")
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.primary)
                                Text(journey.legs.filter { $0.mode != "WALK" }
                                    .map { $0.line ?? "MPK" }.joined(separator: " → "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text("Przyjazd \(journey.arrival.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if firstRide.realTime {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(firstRide.delaySeconds.map { delayLabel(TimeInterval($0)) } ?? "Na żywo")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(firstRide.delaySeconds.map { transitDelayColor($0) } ?? Color.accentColor)
                                    Text(transitTimeSourceLabel(for: firstRide, in: journey))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("wg rozkładu")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Wybierz późniejsze połączenie")
                }
            }
        }
    }

    func compactTitle(for mode: TransportMode) -> String {
        switch mode {
        case .car: "Auto"
        case .walking: "Pieszo"
        case .bicycle: "Rower"
        case .transit: "Komunikacja"
        case .parkRide: "P+R"
        }
    }

    @ViewBuilder
    var waypointDetails: some View {
        if !engine.state.waypoints.isEmpty {
            HStack {
                Label("Przystanki pośrednie", systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.semibold))
                Text("\(engine.state.waypoints.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if engine.state.waypoints.count >= 2 {
                    Button("Optymalizuj", systemImage: "arrow.triangle.swap") {
                        Task { await engine.optimizeWaypoints() }
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(engine.state.status != .routePreview)
                }
            }
        }
    }

    var routeEndpoints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trasa")
                .font(.subheadline.weight(.semibold))
            Label(engine.state.routeOrigin?.name ??
                  (engine.state.location == nil ? "Pozycja niedostępna" : "Moja lokalizacja"),
                  systemImage: engine.state.routeOrigin?.isCurrentLocation == false ? "a.circle.fill" : "location.fill")
                .font(.subheadline)
                .foregroundStyle(engine.state.location == nil ? Color.secondary : Color.primary)
            Label(engine.state.destination?.name ?? "Cel podróży",
                  systemImage: "mappin.and.ellipse")
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    func routePreferenceToggle(_ title: String,
                                      keyPath: WritableKeyPath<RoutingPreferences, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { engine.state.routingPreferences[keyPath: keyPath] },
            set: { value in
                var preferences = engine.state.routingPreferences
                preferences[keyPath: keyPath] = value
                Task { await engine.updateRoutingPreferences(preferences) }
            }
        ))
        .font(.subheadline)
    }

    func routeOption(_ route: NavigationRoute, index: Int,
                             selectedRoute: NavigationRoute, isSelected: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                engine.select(route)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(routeOptionTime(route, selectedRoute: selectedRoute, isSelected: isSelected))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(routeTransitSummary(route) ?? distance(route.distance))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 9)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.42) : Color.primary.opacity(0.05))
            }
        }
        .buttonStyle(.plain)
        .disabled(engine.state.transitPlanningPhase == .enrichingGeometry)
        .accessibilityLabel("Trasa \(index), \(time(route.expectedTravelTime)), \(distance(route.distance))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    func routeTransitSummary(_ route: NavigationRoute) -> String? {
        guard let journey = route.journey else { return nil }
        let lines = journey.legs.filter { $0.mode != "WALK" }.compactMap(\.line)
        guard !lines.isEmpty else { return nil }
        let walkingMinutes = journey.legs.filter { $0.mode == "WALK" }
            .reduce(0) { $0 + max(0, Int(ceil($1.arrival.timeIntervalSince($1.departure) / 60))) }
        return lines.joined(separator: " → ") + (walkingMinutes > 0 ? " · pieszo \(walkingMinutes) min" : "")
    }

    func routeOptionTime(_ route: NavigationRoute, selectedRoute: NavigationRoute,
                                 isSelected: Bool) -> String {
        guard !isSelected else { return compactRouteTime(route.expectedTravelTime) }
        let difference = route.expectedTravelTime - selectedRoute.expectedTravelTime
        let minutes = Int(ceil(abs(difference) / 60))
        guard minutes > 0 else { return compactRouteTime(route.expectedTravelTime) }
        return "\(difference > 0 ? "+" : "−")\(minutes) min"
    }

    func compactRouteTime(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int(ceil(seconds / 60)))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        guard hours > 0 else { return "\(totalMinutes) min" }
        return "\(hours):\(String(format: "%02d", minutes))"
    }

    func transitMetricTime(_ seconds: TimeInterval) -> String {
        seconds > 0 ? compactRouteTime(seconds) : "0 min"
    }
}
