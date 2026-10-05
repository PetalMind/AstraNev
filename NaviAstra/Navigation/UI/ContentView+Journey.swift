import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

private enum JourneySummaryMetricEmphasis {
    case primary
    case secondary
    case tertiary

    var valueSize: CGFloat {
        switch self {
        case .primary: 24
        case .secondary: 20
        case .tertiary: 18
        }
    }

    var valueWeight: Font.Weight {
        switch self {
        case .primary: .bold
        case .secondary: .semibold
        case .tertiary: .medium
        }
    }
}

extension ContentView {
    var journeyPanel: some View {
#if os(iOS)
        journeyNavigationPanel()
#else
        desktopJourneyPanel
#endif
    }

    @ViewBuilder
    var journeyNavigationGuidanceOverlay: some View {
#if os(iOS)
        if isNavigating {
            Group {
                if showsRoadManeuverTimeline || isOnRoadDrivingLeg {
                    VStack(alignment: .leading, spacing: 0) {
                        currentStepGuidanceCard

                        if isCurrentStepGuidanceExpanded, nextRoadManeuverAfterCurrent != nil {
                            journeyGuidanceDivider
                            if journeyGuidanceExpanded {
                                journeyRoadManeuverTimeline
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            } else {
                                journeyNextStepPreview
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            if upcomingRoadManeuvers.count > 2 {
                                journeyGuidanceDivider
                                Button {
                                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                                        journeyGuidanceExpanded.toggle()
                                    }
                                } label: {
                                    Label(journeyGuidanceExpanded ? "Ukryj kroki" : "Pokaż wszystkie kroki",
                                          systemImage: journeyGuidanceExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .padding(.horizontal, 14)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(journeyGuidanceExpanded
                                                    ? "Ukryj pozostałe manewry"
                                                    : "Pokaż wszystkie pozostałe manewry")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(NavigationGlassSurface(radius: 26))
                } else if parkRideIsUsingTransitLeg {
                    transitNavigationHeader
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
#else
        EmptyView()
#endif
    }

    private var journeyGuidanceDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.16))
            .frame(height: 1)
            .padding(.leading, 78)
            .padding(.trailing, 14)
    }

    var isCurrentStepGuidanceExpanded: Bool {
        if let currentStepExpandedOverride { return currentStepExpandedOverride }
        return navigationStore.state.status == .rerouting || currentStepGuidanceDistance <= 1_000
    }

    @ViewBuilder
    var currentStepGuidanceCard: some View {
        Group {
            if isCurrentStepGuidanceExpanded {
                maneuverCard
                    .contentShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                    .onTapGesture {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                            currentStepExpandedOverride = false
                        }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Stuknij, aby zwinąć informacje o kroku")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                compactCurrentStepGuidance
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: isCurrentStepGuidanceExpanded)
    }

    private var currentStepGuidanceDistance: Double {
        if let distance = navigationStore.state.progress?.distanceToNextManeuver, distance.isFinite {
            return distance
        }
        if navigationStore.state.transportMode == .parkRide,
           let distance = parkRideCarDistanceToTransfer {
            return distance
        }
        return navigationStore.state.progress?.remainingDistance ?? .infinity
    }

    private var compactCurrentStepGuidance: some View {
        let maneuver = navigationStore.state.progress?.nextManeuver
        let fallbackSymbol = navigationStore.state.transportMode == .parkRide
            ? "parkingsign.circle.fill" : "arrow.up"
        let instruction = maneuver?.displayInstruction
            ?? (navigationStore.state.transportMode == .parkRide
                ? "Jedź do parkingu P+R" : "Kontynuuj do celu")

        return Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                currentStepExpandedOverride = true
            }
        } label: {
            HStack(spacing: 10) {
                ManeuverIcon(type: maneuver?.type, fallbackSymbol: maneuver?.iconName ?? fallbackSymbol, size: 25, roundabout: maneuver?.roundabout)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(instruction)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.naviTextPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    if let streetLine = maneuver?.streetLine {
                        Text(streetLine)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.naviTextSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.naviTextSecondary)
                    .frame(width: 18, height: 18)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(instruction)
        .accessibilityHint("Rozwiń informacje o kroku")
    }

    func journeyNavigationPanel(maxHeight: CGFloat = 560) -> some View {
        NavigationBottomSheet(detent: $navigationPanelDetent,
                              maximumHeight: maxHeight,
                              accessibilityLabel: "Panel prowadzenia",
                              isDragging: $isMapBottomSheetDragging,
                              mediumHeightFraction: navigationStore.state.transportMode == .transit ? 0.62 : 0.30,
                              minimumPeekHeight: navigationStore.state.transportMode == .transit ? 156 : nil,
                              minimumMediumHeight: navigationStore.state.transportMode == .transit ? nil : 280,
                              resizesFromContent: false,
                              onClose: navigationStore.state.transportMode == .transit
                                ? { navigationStore.stop() } : nil,
                              closeAccessibilityLabel: "Zakończ nawigację") { detent, _ in
            VStack(spacing: 0) {
                if navigationStore.state.transportMode == .transit {
                    if let transitLeg = activeTransitLeg {
                        if detent != .peek {
                            transitNavigationStepPanel(transitLeg, expanded: detent == .expanded)
                                .padding(.horizontal, 20)
                                .padding(.top, 8)

                            if detent == .expanded {
                                if let journey = navigationStore.state.route?.journey {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Cel podróży").font(.caption)
                                                .foregroundStyle(Color.naviTextSecondary)
                                            Text(navigationStore.state.destination?.name ?? journey.legs.last?.to ?? "Cel")
                                                .font(.subheadline.weight(.semibold))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer(minLength: 12)
                                        VStack(alignment: .trailing, spacing: 4) {
                                            Text("Przyjazd wg trasy").font(.caption)
                                                .foregroundStyle(Color.naviTextSecondary)
                                            Text(journey.arrival.formatted(date: .omitted, time: .shortened))
                                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                        }
                                    }
                                    .padding(14)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                                    .padding(.horizontal, 20)
                                    .padding(.top, 16)
                                }
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showsFullTransitItinerary.toggle()
                                    }
                                } label: {
                                    Label(showsFullTransitItinerary
                                          ? "Ukryj pełny przebieg" : "Pokaż pełny przebieg",
                                          systemImage: showsFullTransitItinerary ? "chevron.up" : "chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 20)
                                .padding(.top, 4)

                                if showsFullTransitItinerary {
                                    transitJourneyTimeline
                                        .padding(.horizontal, 18)
                                        .padding(.top, 4)
                                }

                            }

                            journeyNavigationQuickActions
                                .padding(.horizontal, 18)
                                .padding(.top, 8)
                        } else {
                            transitCompactNavigationSummary(transitLeg)
                                .padding(.horizontal, 18)
                                .padding(.top, detent == .peek ? 0 : 4)
                        }
                    } else {
                        ContentUnavailableView(
                            "Brak aktywnego etapu",
                            systemImage: "tram.fill",
                            description: Text("Nie ma teraz szczegółów kolejnego odcinka podróży."))
                            .padding(.horizontal, 18)
                    }
                } else {
                    if detent == .expanded && isOnRoadDrivingLeg {
                        navigationRoadAlertsPanel
                            .padding(.horizontal, 18)
                            .padding(.bottom, 12)
                    }
                    journeyNavigationSummaryRow(detent: detent)
                        .padding(.horizontal, 18)
                        .padding(.top, detent == .peek ? 0 : 4)

                    if detent == .expanded {
                        journeyDestinationRow
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                    }

                    if detent == .expanded, navigationStore.state.transportMode == .parkRide {
                        parkRideJourneyTimeline
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                    }

                    if detent != .peek {
                        journeyNavigationQuickActions
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                    }
                }
            }
            .padding(.bottom, detent == .peek ? 2 : 10)
        } footer: { detent, _ in
            if detent == .expanded {
                VStack(spacing: 0) {
                    journeyNavigationPrimaryActions
                        .padding(.horizontal, 18)
                        .padding(.top, 10)

                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 1)

                    Button(role: .destructive) {
                        navigationStore.stop()
                    } label: {
                        Label("Zakończ nawigację", systemImage: "stop.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(Color(naviHex: NaviAstraColorPalette.danger))
                            .background(Color(naviHex: NaviAstraColorPalette.danger).opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 18)
                }
            }
        }
    }

    private func transitCompactNavigationSummary(_ leg: JourneyLeg) -> some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let remainingStops = transitProgress(for: leg)?.stopsUntilAlighting
            let arrival = activeTransitArrival(for: leg)
            let boarding = leg.mode.uppercased() != "WALK" && transitProgress(for: leg)?.isOnVehicle != true
            let firstStop = leg.transitStops.min { $0.sequence < $1.sequence }
            let departure = firstStop.flatMap { liveTransitStop($0.stopID, for: leg)?.departure }
                ?? firstStop?.departure ?? leg.departure
            let remainingTime = leg.mode.uppercased() == "WALK"
                ? (transitProgress(for: leg).map { $0.distanceToLegEnd / 1.25 }
                   ?? max(0, arrival.timeIntervalSince(context.date)))
                : max(0, arrival.timeIntervalSince(context.date))

            HStack(spacing: 12) {
                transitNavigationLineBadge(for: leg)
                VStack(alignment: .leading, spacing: 3) {
                    Text(transitNavigationInstruction(for: leg))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.naviTextPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(leg.mode.uppercased() == "WALK"
                         ? "Pieszo · około \(compactRouteTime(remainingTime))"
                         : boarding ? "Odjazd \(departure.formatted(date: .omitted, time: .shortened))"
                         : "\(remainingStops.map { transitStopCountText($0) + " · " } ?? "")\(compactRouteTime(remainingTime))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.naviTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func transitNavigationStepPanel(_ leg: JourneyLeg, expanded: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let tracking = transitProgress(for: leg)
            let walking = leg.mode.uppercased() == "WALK"
            let boarding = !walking && tracking?.isOnVehicle != true
            let orderedStops = leg.transitStops.sorted { $0.sequence < $1.sequence }
            let departure = orderedStops.first.flatMap { liveTransitStop($0.stopID, for: leg)?.departure }
                ?? orderedStops.first?.departure ?? leg.departure
            let arrival = activeTransitArrival(for: leg)
            let nextStop = upcomingTransitStops(for: leg, at: context.date, tracking: tracking).first
            let remainingStops = tracking?.stopsUntilAlighting
            let walkingTime = tracking.map { $0.distanceToLegEnd / 1.25 }
                ?? max(0, arrival.timeIntervalSince(context.date))

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    transitNavigationLineBadge(for: leg)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(walking ? "DOJŚCIE PIESZO" : boarding ? "WSIĄDŹ NA PRZYSTANKU" : "WYSIĄDŹ NA PRZYSTANKU")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.naviTextSecondary)
                        Text(boarding ? leg.from : leg.to)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color.naviTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !walking {
                            Text("Kierunek: \(leg.direction ?? leg.to)")
                                .font(.subheadline)
                                .foregroundStyle(Color.naviTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if walking {
                    Label("Około \(compactRouteTime(walkingTime)) pieszo", systemImage: "figure.walk")
                        .font(.subheadline.weight(.semibold))
                    if let legs = navigationStore.state.route?.journey?.legs,
                       let index = legs.firstIndex(where: { $0.id == leg.id }),
                       let nextRide = legs.dropFirst(index + 1).first(where: { $0.mode.uppercased() != "WALK" }) {
                        HStack(spacing: 10) {
                            transitNavigationLineBadge(for: nextRide)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Następnie: \(nextRide.direction ?? nextRide.to)")
                                    .font(.subheadline.weight(.semibold))
                                Text("Odjazd \(nextRide.departure.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Color.naviTextSecondary)
                            }
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(boarding ? "Odjazd" : "Do wysiadki")
                                .font(.caption).foregroundStyle(Color.naviTextSecondary)
                            Text(boarding ? departure.formatted(date: .omitted, time: .shortened)
                                 : compactRouteTime(max(0, arrival.timeIntervalSince(context.date))))
                                .font(.title3.weight(.bold).monospacedDigit())
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            if boarding {
                                Text(departure > context.date ? "Za \(transitETA(departure, now: context.date))" : "Sprawdź odjazd na przystanku")
                                    .font(.subheadline.weight(.semibold))
                            } else if let remainingStops {
                                Text(transitStopCountText(remainingStops))
                                    .font(.subheadline.weight(.semibold))
                            }
                            if let journey = navigationStore.state.route?.journey {
                                Text(transitTimeSourceLabel(for: leg, in: journey))
                                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                    if let delay = displayedTransitDelay(for: leg), abs(delay) >= 30 {
                        Label(delayLabel(TimeInterval(delay)), systemImage: "clock.badge.exclamationmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(transitDelayColor(delay))
                    }
                    if !boarding, let nextStop {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Następny przystanek")
                                .font(.caption).foregroundStyle(Color.naviTextSecondary)
                            Text(nextStop.name).font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if expanded {
                    Divider()
                    transitNavigationStopTimeline(
                        origin: leg.from, originTime: departure,
                        destination: leg.to, destinationTime: arrival,
                        rideDescription: walking ? "Dojście pieszo" : "Przejazd do przystanku wysiadania")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    private func transitNavigationStopTimeline(origin: String,
                                               originTime: Date,
                                               destination: String,
                                               destinationTime: Date,
                                               rideDescription: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(rideDescription, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.caption.weight(.medium)).foregroundStyle(Color.naviTextSecondary)
            ForEach(0..<2, id: \.self) { index in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: index == 0 ? "circle" : "largecircle.fill.circle")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(index == 0 ? "Początek etapu" : "Koniec etapu")
                            .font(.caption).foregroundStyle(Color.naviTextSecondary)
                        Text(index == 0 ? origin : destination)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text((index == 0 ? originTime : destinationTime).formatted(date: .omitted, time: .shortened))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.naviTextSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func transitNavigationLineBadge(for leg: JourneyLeg) -> some View {
        Group {
            if let line = leg.line, !line.isEmpty {
                Text(line)
                    .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.black.opacity(0.68))
            } else {
                Image(systemName: transitLegSymbol(for: leg))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.62))
            }
        }
        .frame(minWidth: 46, minHeight: 42)
        .padding(.horizontal, 3)
        .background(Color.white.opacity(0.9), in: Capsule())
        .overlay(Capsule().stroke(mapTransitColor(leg.lineColorHex ?? NaviAstraColorPalette.transitFallback), lineWidth: 3))
        .accessibilityLabel(leg.line.map { "Linia \($0)" } ?? leg.mode)
    }

    private func transitNavigationInstruction(for leg: JourneyLeg) -> String {
        if leg.mode.uppercased() == "WALK" { return "Idź do \(leg.to)" }
        if transitProgress(for: leg)?.isOnVehicle != true { return "Wsiądź na \(leg.from)" }
        return "Wysiądź na \(leg.to)"
    }

    private func activeTransitArrival(for leg: JourneyLeg) -> Date {
        guard let finalStop = leg.transitStops.max(by: { $0.sequence < $1.sequence }) else {
            return leg.arrival
        }
        return liveTransitStop(finalStop.stopID, for: leg)?.arrival ?? finalStop.arrival
    }

    private func journeyNavigationSummaryRow(detent: NavigationBottomSheetDetent) -> some View {
        let remainingTime = journeyRemainingTime
        let remainingDistance = navigationStore.state.progress?.remainingDistance

        return Button {
            navigationPanelDetent = detent == .expanded ? .medium : .expanded
        } label: {
            HStack(spacing: 4) {
                journeySummaryMetric(value: remainingTime.map(arrivalTime) ?? "—", caption: "ETA",
                                     emphasis: .primary)
                    .frame(maxWidth: .infinity, alignment: .center)
                journeySummaryMetric(value: remainingTime.map(time) ?? "—", caption: "Pozostało",
                                     emphasis: .secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                journeySummaryMetric(value: remainingDistance.map(distance) ?? "—", caption: "Do celu",
                                     emphasis: .tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(journeyETAAccessibilityLabel(time: remainingTime, distance: remainingDistance))
        .accessibilityHint(detent == .expanded ? "Zwiń panel prowadzenia" : "Rozwiń panel prowadzenia")
        .foregroundStyle(Color.naviTextPrimary)
    }

    private var journeyNavigationQuickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pozostałe opcje")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.naviTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
                Menu {
                    mapLayerMenuActions
                } label: {
                    journeyNavigationActionLabel("Wygląd i warstwy", symbol: "square.3.layers.3d")
                }
                .accessibilityLabel("Wygląd i warstwy mapy")

                if supportsActiveTripTrafficDetails {
                    Button { appRouter.present(.trafficDetails) } label: {
                        journeyNavigationActionLabel("Ruch na żywo", symbol: "car.side")
                    }
                }

                if supportsActiveTripDestinationParking {
                    Button { presentNearby(.parking, nearDestination: true) } label: {
                        journeyNavigationActionLabel("Parking przy celu", symbol: "parkingsign.circle")
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var journeyNavigationPrimaryActions: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(activeJourneyNearbyCategories) { category in
                    Button(category.title, systemImage: category.symbol) {
                        presentNearbyAfterMenuDismissal(category)
                    }
                }
            } label: {
                journeyNavigationActionLabel("Po trasie", symbol: "magnifyingglass")
            }
            .frame(maxWidth: .infinity)

            if supportsActiveTripWaypoints {
                Button {
                    addingWaypoint = true
                    appRouter.present(.search)
                } label: {
                    journeyNavigationActionLabel("Dodaj przystanek", symbol: "plus.circle")
                }
                .buttonStyle(.plain)
                .disabled(navigationStore.state.waypoints.count >= 8)
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
    }

    private func journeyNavigationActionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.naviTextPrimary)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var journeyNextStepPreview: some View {
        if showsRoadManeuverTimeline, let next = nextRoadManeuverAfterCurrent {
            HStack(spacing: 11) {
                ManeuverIcon(type: next.maneuver.type, fallbackSymbol: next.maneuver.iconName, size: 20, roundabout: next.maneuver.roundabout)
                    .foregroundStyle(Color.naviTextPrimary)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Następnie: \(next.maneuver.displayInstruction)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.naviTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    if let streetLine = next.maneuver.streetLine {
                        Text(streetLine)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.naviTextSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let stepDistance = next.distance, stepDistance > 0 {
                    Text(distance(stepDistance))
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.naviTextSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Następnie: \(next.maneuver.displayInstruction)\(next.distance.map { ", za \(distance($0))" } ?? "")")
        }
    }

    private var nextRoadManeuverAfterCurrent: (maneuver: Maneuver, distance: Double?)? {
        guard let route = navigationStore.state.route,
              let progress = navigationStore.state.progress,
              progress.geometryRouteID == route.id,
              let current = progress.nextManeuver,
              let currentIndex = route.maneuvers.firstIndex(where: { $0.id == current.id }),
              route.maneuvers.indices.contains(currentIndex + 1) else { return nil }

        let next = route.maneuvers[currentIndex + 1]
        return (next, routeDistance(from: current.shapeIndex,
                                    through: next.shapeIndex,
                                    on: route.coordinates))
    }

    private var journeyRemainingTime: TimeInterval? {
        if navigationStore.state.transportMode == .transit,
           let arrival = navigationStore.state.route?.journey?.arrival {
            return max(0, arrival.timeIntervalSinceNow)
        }
        return navigationStore.state.progress?.remainingTime
    }

    private var journeyMediumDestinationSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Cel podróży")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.naviTextSecondary)
                Text(navigationStore.state.destination?.name ?? "")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.naviTextPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var showsRoadManeuverTimeline: Bool {
        switch navigationStore.state.transportMode {
        case .car, .walking, .bicycle: true
        case .transit: false
        case .parkRide: parkRideIsDrivingLeg
        }
    }

    private var upcomingRoadManeuvers: [Maneuver] {
        guard let route = navigationStore.state.route, !route.maneuvers.isEmpty else { return [] }
        guard let progress = navigationStore.state.progress,
              progress.geometryRouteID == route.id else { return route.maneuvers }
        guard let nextManeuver = progress.nextManeuver,
              let index = route.maneuvers.firstIndex(where: { $0.id == nextManeuver.id }) else { return [] }
        return Array(route.maneuvers.dropFirst(index))
    }

    private var journeyRoadManeuverStartShapeIndex: Int {
        guard let route = navigationStore.state.route,
              let progress = navigationStore.state.progress,
              progress.geometryRouteID == route.id,
              let current = progress.nextManeuver else { return 0 }
        return current.shapeIndex
    }

    @ViewBuilder
    private var journeyRoadManeuverTimeline: some View {
        if let route = navigationStore.state.route {
            RouteInformationView(route: route).id(route.id)
                .padding(.horizontal, 14)
            if route.maneuvers.isEmpty {
                Label("Instrukcje manewrów niedostępne", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Color.naviTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
            } else {
                let upcoming = upcomingRoadManeuvers
                let maneuvers = Array(upcoming.dropFirst())
                if !maneuvers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pozostałe manewry")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.naviTextPrimary)

                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(maneuvers.enumerated()), id: \.element.id) { index, maneuver in
                                    let previousShapeIndex = index == 0
                                        ? (upcoming.first?.shapeIndex ?? journeyRoadManeuverStartShapeIndex)
                                        : maneuvers[index - 1].shapeIndex
                                    journeyRoadManeuverRow(
                                        maneuver,
                                        distanceToStep: routeDistance(
                                            from: previousShapeIndex,
                                            through: maneuver.shapeIndex,
                                            on: route.coordinates),
                                        isCurrent: false)

                                    if index < maneuvers.count - 1 {
                                        Rectangle()
                                            .fill(Color.primary.opacity(0.15))
                                            .frame(width: 2, height: 12)
                                            .padding(.leading, 15)
                                    }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: 220)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func journeyRoadManeuverRow(_ maneuver: Maneuver,
                                       distanceToStep: Double?,
                                       isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ManeuverIcon(type: maneuver.type, fallbackSymbol: maneuver.iconName, size: 19, roundabout: maneuver.roundabout)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.naviTextSecondary)
                .frame(width: 32, height: 32)
                .background(isCurrent ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(maneuver.displayInstruction)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.naviTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if isCurrent {
                        Text("Teraz")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    } else if let distanceToStep, distanceToStep > 0 {
                        Text(distance(distanceToStep))
                            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.naviTextSecondary)
                            .lineLimit(1)
                    }
                }
                if let streetLine = maneuver.streetLine {
                    Text(streetLine)
                        .font(.caption)
                        .foregroundStyle(Color.naviTextSecondary)
                        .lineLimit(1)
                }
                ManeuverInformationView(maneuver: maneuver)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func routeDistance(from startIndex: Int, through endIndex: Int,
                               on coordinates: [Coordinate]) -> Double? {
        guard startIndex >= 0, endIndex > startIndex,
              endIndex < coordinates.count else { return nil }
        var totalDistance = 0.0
        for index in startIndex..<endIndex {
            totalDistance += coordinates[index].distance(to: coordinates[index + 1])
        }
        return totalDistance
    }

    private func journeyETAAccessibilityLabel(time remainingTime: TimeInterval?, distance remainingDistance: Double?) -> String {
        switch (remainingTime, remainingDistance) {
        case let (remainingTime?, remainingDistance?):
            "Przyjazd o \(arrivalTime(remainingTime)), pozostało \(distance(remainingDistance)) i \(time(remainingTime))"
        case let (remainingTime?, nil):
            "Przyjazd o \(arrivalTime(remainingTime)), pozostało \(time(remainingTime))"
        case let (nil, remainingDistance?):
            "Pozostało \(distance(remainingDistance))"
        case (nil, nil):
            "Dane przyjazdu niedostępne"
        }
    }

    var journeyDestinationRow: some View {
        let currentLeg = currentJourneyLeg
        return HStack(spacing: 12) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(activeJourneyTargetText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if let following = currentLeg?.following {
                    Text("Po dotarciu: \(following.name)")
                        .font(.caption)
                        .foregroundStyle(Color.naviTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.naviTextPrimary)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .modifier(NavigationGlassSurface(radius: 18))
        .accessibilityElement(children: .combine)
    }

    private func journeySummaryMetric(value: String, caption: String,
                                      emphasis: JourneySummaryMetricEmphasis) -> some View {
        VStack(alignment: .center, spacing: 2) {
            Text(value)
                .font(.system(size: emphasis.valueSize,
                              weight: emphasis.valueWeight,
                              design: .rounded).monospacedDigit())
                .foregroundStyle(Color.naviTextPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(caption)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.naviTextSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    var journeyActionsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
            if activeJourneyNearbyCategories.count == 1,
               let category = activeJourneyNearbyCategories.first {
                Button { presentNearby(category) } label: {
                    journeyActionLabel("\(category.title) po drodze", symbol: category.symbol)
                }
            } else {
                Menu {
                    ForEach(activeJourneyNearbyCategories) { category in
                        Button(category.title, systemImage: category.symbol) {
                            presentNearbyAfterMenuDismissal(category)
                        }
                    }
                } label: {
                    journeyActionLabel("Po trasie", symbol: "magnifyingglass")
                }
            }
#if os(macOS)
            if supportsActiveTripWaypoints {
                Button {
                    addingWaypoint = true
                    appRouter.present(.search)
                } label: {
                    journeyActionLabel("Przystanek", symbol: "plus.circle")
                }
                .disabled(navigationStore.state.waypoints.count >= 8)
            }
            Button {
                navigationStore.showRouteOverview()
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    navigationPanelExpanded = false
                }
            } label: {
                journeyActionLabel("Cała trasa", symbol: "map")
            }
#endif
            if supportsActiveTripRoadPreferences {
                Button {
                    routePlanningStore.loadPreferences(from: navigationStore)
                    appRouter.present(.routeSettings)
                } label: {
                    journeyActionLabel(navigationStore.state.transportMode == .parkRide ? "Opcje jazdy" : "Opcje trasy",
                                       symbol: "slider.horizontal.3")
                }
            }
            journeyMapLayersMenu
            if supportsActiveTripTrafficDetails {
                Button { appRouter.present(.trafficDetails) } label: {
                    journeyActionLabel("Ruch na żywo", symbol: "car.side")
                }
            }
            if supportsActiveTripDestinationParking {
                Button { presentNearby(.parking, nearDestination: true) } label: {
                    journeyActionLabel("Parking na miejscu", symbol: "parkingsign.circle")
                }
            }
        }
        .buttonStyle(.plain)
    }

    var desktopJourneyPanel: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    navigationPanelExpanded.toggle()
                }
            } label: {
                HStack(spacing: 0) {
                    metric(value: time(navigationStore.state.progress?.remainingTime ?? 0), caption: "do celu")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metric(value: distance(navigationStore.state.progress?.remainingDistance ?? 0), caption: "pozostało")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metric(value: arrivalTime(navigationStore.state.progress?.remainingTime ?? 0), caption: navigationArrivalCaption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: navigationPanelExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.naviTextSecondary)
                        .padding(.leading, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(navigationPanelExpanded ? "Zwiń panel prowadzenia" : "Rozwiń panel prowadzenia")
            .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height < -35 {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { navigationPanelExpanded = true }
                } else if value.translation.height > 35 {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { navigationPanelExpanded = false }
                }
            })

            if navigationStore.state.transportMode == .transit, let transitLeg = activeTransitLeg {
                if transitLeg.mode == "WALK" {
                    transitWalkNavigationCard(transitLeg)
                } else {
                    transitNavigationCard(transitLeg)
                }
            } else if let currentLeg = currentJourneyLeg {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activeJourneyTargetText)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let following = currentLeg.following {
                            Text("Po dotarciu: \(following.name)")
                                .font(.caption)
                                .foregroundStyle(Color.naviTextSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .combine)
            }

            if navigationPanelExpanded {
                Divider()
                Text("W trakcie podróży")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                journeyActionsGrid
                if navigationStore.state.transportMode == .transit {
                    transitJourneyTimeline
                } else if navigationStore.state.transportMode == .parkRide {
                    parkRideJourneyTimeline
                }
                Divider()
                Button(role: .destructive) { navigationStore.stop() } label: {
                    Label("Zakończ nawigację", systemImage: "stop.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(Color(naviHex: NaviAstraColorPalette.danger))
                        .background(Color(naviHex: NaviAstraColorPalette.danger).opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .modifier(NavigationGlassSurface(radius: 23))
    }

    func journeyActionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.naviTextPrimary)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    var currentJourneyLeg: (current: Destination, following: Destination?)? {
        guard let route = navigationStore.state.route, let destination = navigationStore.state.destination else { return nil }
        var stops = navigationStore.state.waypoints + navigationStore.state.evChargingStops
        if !stops.contains(where: { $0.coordinate == destination.coordinate }) { stops.append(destination) }
        let ordered = stops.compactMap { stop -> (Destination, Double)? in
            guard let projection = MapMatcher.project(stop.coordinate, onto: route.coordinates) else { return nil }
            return (stop, projection.alongRoute)
        }.sorted { $0.1 < $1.1 }
        guard !ordered.isEmpty else { return (destination, nil) }
        let routeLength = zip(route.coordinates, route.coordinates.dropFirst())
            .reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        let progressFraction = route.distance > 0
            ? (navigationStore.state.progress?.traveledDistance ?? 0) / route.distance : 0
        let traveledGeometry = routeLength * max(0, min(1, progressFraction))
        let currentIndex = ordered.firstIndex { $0.1 > traveledGeometry + 30 } ?? (ordered.count - 1)
        return (ordered[currentIndex].0,
                ordered.indices.contains(currentIndex + 1) ? ordered[currentIndex + 1].0 : nil)
    }

    var activeTransitLegIndex: Int? {
        guard let legs = navigationStore.state.route?.journey?.legs, !legs.isEmpty else { return nil }
        if let tracked = navigationStore.state.transitProgress?.legIndex, legs.indices.contains(tracked) {
            return tracked
        }
        return legs.firstIndex { leg in
            let liveArrival = liveTransitTripDetails?.tripID == leg.tripID
                ? liveTransitTripDetails?.nextStops.last?.arrival : nil
            return (liveArrival ?? leg.arrival) > Date()
        } ?? legs.indices.last
    }

    var activeTransitLeg: JourneyLeg? {
        guard let legs = navigationStore.state.route?.journey?.legs,
              let index = activeTransitLegIndex, legs.indices.contains(index) else { return nil }
        return legs[index]
    }

    func transitProgress(for leg: JourneyLeg) -> TransitNavigationProgress? {
        guard let legs = navigationStore.state.route?.journey?.legs,
              let progress = navigationStore.state.transitProgress,
              legs.indices.contains(progress.legIndex),
              legs[progress.legIndex].id == leg.id else { return nil }
        return progress
    }

    func liveTransitDetails(for leg: JourneyLeg) -> TransitTripDetails? {
        guard liveTransitTripDetails?.tripID == leg.tripID else { return nil }
        return liveTransitTripDetails
    }

    func liveTransitStop(_ stopID: String, for leg: JourneyLeg) -> TransitJourneyStop? {
        guard let details = liveTransitDetails(for: leg) else { return nil }
        return details.nextStops.first(where: { $0.stopID == stopID })
            ?? details.pastStops.first(where: { $0.stopID == stopID })
    }

    func displayedTransitDelay(for leg: JourneyLeg) -> Int? {
        let liveAlightingDelay = leg.transitStops.last.flatMap {
            liveTransitStop($0.stopID, for: leg)?.delaySeconds
        }
        let liveUpcomingDelay = liveTransitDetails(for: leg)?.nextStops
            .first(where: { $0.delaySeconds != nil })?.delaySeconds
        return liveAlightingDelay ?? liveUpcomingDelay ?? leg.delaySeconds
    }

    func hasLiveTransitUpdate(for leg: JourneyLeg) -> Bool {
        guard navigationStore.state.route?.journey?.realtimeFreshness == .live else { return false }
        guard let details = liveTransitDetails(for: leg) else { return false }
        return details.nextStops.contains(where: { $0.hasRealtime })
            || details.pastStops.contains(where: { $0.hasRealtime })
    }

    func transitTimeSourceLabel(for leg: JourneyLeg, in journey: Journey) -> String {
        guard leg.realTime || hasLiveTransitUpdate(for: leg) else { return "wg rozkładu" }
        switch journey.realtimeFreshness {
        case .live: return "Na żywo"
        case .degraded: return "Realtime opóźnione"
        case .stale: return "Realtime nieświeże"
        case .unavailable: return "Realtime bez potwierdzonej świeżości"
        }
    }

    func transitRealtimeStatus(for journey: Journey) -> String {
        if journey.sourceID != nil {
            return journey.realtimeFeedAvailable
                ? "Dane realtime zwrócone przez Transitous"
                : "Aktualne odjazdy według rozkładu Transitous"
        }
        let time = journey.realtimeFeedUpdatedAt?.formatted(date: .omitted, time: .shortened)
        switch journey.realtimeFreshness {
        case .live:
            return "Aktualizacje opóźnień na żywo · \(time ?? "teraz")"
        case .degraded:
            return "Opóźnione aktualizacje realtime · \(time ?? "bez czasu")"
        case .stale:
            return "Dane realtime są nieświeże · pokazano rozkład"
        case .unavailable:
            return "Dane o opóźnieniach niedostępne · pokazano rozkład"
        }
    }

    func transitFreshnessIndicator(for journey: Journey) -> some View {
        let presentation = switch journey.realtimeFreshness {
        case .live: ("dot.radiowaves.left.and.right", Color(naviHex: NaviAstraColorPalette.success))
        case .degraded: ("clock.badge.exclamationmark", Color(naviHex: NaviAstraColorPalette.warning))
        case .stale: ("clock", Color.naviTextInactive)
        case .unavailable: ("minus.circle", Color(naviHex: NaviAstraColorPalette.info))
        }
        return Label(transitRealtimeStatus(for: journey), systemImage: presentation.0)
            .font(.caption2.weight(.medium))
            .foregroundStyle(presentation.1)
            .lineLimit(2)
            .accessibilityElement(children: .combine)
    }

    func refreshTransitJourneyDetails() async {
        guard navigationStore.state.transportMode == .transit else {
            transitStore.clearJourneySelection()
            navigationStore.updateTransitTripDetails(nil, tripID: nil)
            return
        }
        while !Task.isCancelled {
            await navigationStore.refreshTransitRouteIfNeeded()
            guard !Task.isCancelled else { return }
            let legs = navigationStore.state.route?.journey?.legs ?? []
            let activeIndex = activeTransitLegIndex ?? 0
            let nextRide = legs.indices.first { index in
                index >= activeIndex && legs[index].tripID != nil
            }.map { legs[$0] }
            if let leg = nextRide, let tripID = leg.tripID {
                let tripDetails: TransitTripDetails?
                if tripID.hasPrefix(TransitousTransitDataProvider.tripIDPrefix) {
                    tripDetails = await transitStore.tripDetails(
                        tripID: tripID, fromStopID: leg.transitStops.first?.stopID)
                } else if let serviceDate = leg.serviceDate,
                          let sequence = leg.transitStops.first?.sequence {
                    tripDetails = await transitStore.tripDetails(
                        tripID: tripID, serviceDate: serviceDate, fromStopSequence: sequence,
                        scheduleShiftSeconds: leg.scheduleShiftSeconds,
                        frequencyStartSeconds: leg.frequencyStartSeconds,
                        frequencyHeadwaySeconds: leg.frequencyHeadwaySeconds,
                        isFrequencyEstimate: leg.isFrequencyEstimate)
                } else {
                    tripDetails = nil
                }
                guard !Task.isCancelled else { return }
                navigationStore.updateTransitTripDetails(tripDetails, tripID: tripID)
                let lineDetails: TransitLineDetails?
                if selectedTransitRouteID == leg.routeID, let selectedTransitLine {
                    lineDetails = selectedTransitLine
                } else if let routeID = leg.routeID {
                    lineDetails = await transitStore.lineDetails(for: routeID)
                } else {
                    lineDetails = nil
                }
                transitStore.selectJourney(leg, tripDetails: tripDetails, lineDetails: lineDetails)
            } else {
                transitStore.clearJourneySelection()
                navigationStore.updateTransitTripDetails(nil, tripID: nil)
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func transitWalkNavigationCard(_ leg: JourneyLeg) -> some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let tracking = transitProgress(for: leg)
            let remaining = tracking.map { max(0, Int(ceil($0.distanceToLegEnd / 1.25 / 60))) }
                ?? max(0, Int(ceil(leg.arrival.timeIntervalSince(context.date) / 60)))
            let nextRide = navigationStore.state.route?.journey?.legs.first {
                $0.mode != "WALK" && $0.departure >= leg.arrival && $0.from == leg.to
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "figure.walk").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor).frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Idź do \(leg.to)").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("Pieszo · około \(remaining) min").font(.caption).foregroundStyle(Color.naviTextSecondary)
                    }
                    Spacer(minLength: 0)
                    if let nextRide {
                        Text(nextRide.departure.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit()).foregroundStyle(Color.naviTextSecondary)
                    }
                }
                if let nextRide {
                    HStack(spacing: 7) {
                        Text(nextRide.line ?? "MPK").font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4)
                            .background(mapTransitColor(nextRide.lineColorHex ?? NaviAstraColorPalette.transitFallback), in: RoundedRectangle(cornerRadius: 7))
                        Text("Następnie · \(nextRide.to)").font(.caption).lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    func transitNavigationCard(_ leg: JourneyLeg) -> some View {
        TimelineView(.periodic(from: .now, by: 20.0)) { context in
            let tracking = transitProgress(for: leg)
            let upcoming = leg.transitStops.filter { $0.arrival > context.date }
            let liveDetails = liveTransitTripDetails?.tripID == leg.tripID ? liveTransitTripDetails : nil
            let liveUpcoming = liveDetails?.nextStops.filter { $0.arrival > context.date } ?? []
            let alightingStopID = leg.transitStops.last?.stopID
            let liveAlightingStop = (liveDetails?.pastStops ?? []).first(where: { $0.stopID == alightingStopID })
                ?? (liveDetails?.nextStops ?? []).first(where: { $0.stopID == alightingStopID })
            let nextStop = tracking?.nextStop ?? liveUpcoming.first ?? upcoming.first
            let displayedDelay = displayedTransitDelay(for: leg)
            let displayedArrival = liveAlightingStop?.arrival ?? leg.arrival
            let minutesUntilDeparture = max(0, Int(ceil(leg.departure.timeIntervalSince(context.date) / 60)))
            let scheduledProgress = leg.transitStops.isEmpty ? 0 :
                Double(leg.transitStops.count - upcoming.count) / Double(leg.transitStops.count)
            let progress = tracking?.legFraction ?? scheduledProgress
            let stopsRemaining = tracking?.stopsUntilAlighting ?? upcoming.count
            let upcomingStops = upcomingTransitStops(for: leg, at: context.date, tracking: tracking)
            let isStopListExpanded = expandedTransitStopsLegID == leg.id
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(leg.line ?? "MPK")
                        .font(.headline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white).frame(minWidth: 42, minHeight: 34)
                        .background(mapTransitColor(leg.lineColorHex ?? NaviAstraColorPalette.transitFallback), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(leg.to).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(minutesUntilDeparture > 0
                             ? "Odjazd za \(transitETA(leg.departure, now: context.date))"
                             : "W podróży · do \(leg.to)")
                            .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    }
                    Spacer(minLength: 0)
                    Text(compactRouteTime(max(0, displayedArrival.timeIntervalSince(context.date))))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                if let nextStop {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                        Text(minutesUntilDeparture > 0 ? "Wsiądź na \(leg.from)" : "Następny · \(nextStop.name)")
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(minutesUntilDeparture > 0
                             ? leg.departure.formatted(date: .omitted, time: .shortened)
                             : transitETA(nextStop.arrival, now: context.date))
                            .font(.caption.monospacedDigit()).foregroundStyle(Color.naviTextSecondary)
                    }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule().fill(Color.accentColor).frame(width: max(8, geometry.size.width * min(1, max(0, progress))))
                        HStack(spacing: 0) {
                            ForEach(leg.transitStops.indices, id: \.self) { index in
                                Circle().fill(Double(index) / Double(max(1, leg.transitStops.count - 1)) <= progress
                                              ? .white : Color.secondary.opacity(0.55))
                                    .frame(width: 5, height: 5)
                                if index < leg.transitStops.count - 1 { Spacer(minLength: 0) }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .frame(height: 8)
                if !leg.transitStops.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedTransitStopsLegID = isStopListExpanded ? nil : leg.id
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text("Jeszcze \(transitStopCountText(stopsRemaining)) do \(leg.to)")
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                            Image(systemName: isStopListExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(Color.naviTextSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isStopListExpanded
                                        ? "Zwiń listę przystanków do \(leg.to)"
                                        : "Pokaż \(transitStopCountText(stopsRemaining)) do \(leg.to)")

                    if isStopListExpanded {
                        transitUpcomingStopsTimeline(leg, stops: upcomingStops,
                                                     activeStopID: nextStop?.stopID)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } else {
                    Text("Jeszcze \(transitStopCountText(stopsRemaining)) do \(leg.to)")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                }
                if let delay = displayedDelay, abs(delay) >= 30 {
                    Text("Rozkład \(leg.departure.formatted(date: .omitted, time: .shortened)) · \(delayLabel(TimeInterval(delay)))")
                        .font(.caption).foregroundStyle(transitDelayColor(delay))
                } else if liveDetails?.nextStops.first?.hasRealtime == true {
                    Label("Aktualizacja na żywo", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    func upcomingTransitStops(for leg: JourneyLeg, at date: Date,
                              tracking: TransitNavigationProgress?) -> [TransitJourneyStop] {
        let stops = leg.transitStops.sorted { $0.sequence < $1.sequence }
        guard !stops.isEmpty else { return [] }

        let liveNextStopID = liveTransitDetails(for: leg)?.nextStops.first?.stopID
        let nextStopID = tracking?.nextStop?.stopID ?? liveNextStopID
        let firstUpcomingIndex = nextStopID.flatMap { stopID in
            stops.firstIndex(where: { $0.stopID == stopID })
        } ?? stops.firstIndex(where: { $0.arrival > date })
            .map { max($0, leg.departure > date ? 1 : 0) }

        guard let firstUpcomingIndex else { return [] }
        return Array(stops.dropFirst(firstUpcomingIndex))
    }

    func transitStopCountText(_ count: Int) -> String {
        let absoluteCount = abs(count)
        let lastTwoDigits = absoluteCount % 100
        let lastDigit = absoluteCount % 10
        let noun: String
        if absoluteCount == 1 {
            noun = "przystanek"
        } else if (2...4).contains(lastDigit) && !(12...14).contains(lastTwoDigits) {
            noun = "przystanki"
        } else {
            noun = "przystanków"
        }
        return "\(count) \(noun)"
    }

    func transitUpcomingStopsTimeline(_ leg: JourneyLeg, stops: [TransitJourneyStop],
                                     activeStopID: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let journey = navigationStore.state.route?.journey {
                transitFreshnessIndicator(for: journey)
                if let headway = journey.frequencyEstimateHeadwaySeconds {
                    Label("Odjazdy orientacyjne co \(max(1, Int((Double(headway) / 60).rounded()))) min",
                          systemImage: "clock.badge.questionmark")
                        .font(.caption).foregroundStyle(Color.naviTextSecondary)
                }
            }

            if stops.isEmpty {
                Text("Brak kolejnych przystanków w danych trasy")
                    .font(.caption)
                    .foregroundStyle(Color.naviTextSecondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                    let isNextStop = stop.stopID == activeStopID
                    let liveStop = liveTransitStop(stop.stopID, for: leg)
                    let arrival = liveStop?.arrival ?? stop.arrival
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 0) {
                            Circle()
                                .fill(isNextStop ? Color.accentColor : Color.secondary.opacity(0.55))
                                .frame(width: isNextStop ? 9 : 7, height: isNextStop ? 9 : 7)
                                .padding(.top, 5)
                            if index < stops.count - 1 {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(width: 1, height: 29)
                                    .padding(.vertical, 3)
                            }
                        }
                        .frame(width: 9)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(stop.name)
                                .font(.caption.weight(isNextStop ? .semibold : .medium))
                                .foregroundStyle(isNextStop ? Color.naviTextPrimary : Color.naviTextSecondary)
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                if isNextStop {
                                    Text("Następny przystanek")
                                }
                                Text(arrival.formatted(date: .omitted, time: .shortened))
                                    .monospacedDigit()
                                if let liveStop, liveStop.hasRealtime,
                                   let journey = navigationStore.state.route?.journey {
                                    Text("·")
                                    Text(transitTimeSourceLabel(for: leg, in: journey))
                                }
                                if let delay = liveStop?.delaySeconds, abs(delay) >= 30 {
                                    Text("·")
                                    Text(delayLabel(TimeInterval(delay)))
                                        .foregroundStyle(transitDelayColor(delay))
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(Color.naviTextSecondary)
                            .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.leading, 3)
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
    }

    var transitJourneyTimeline: some View {
        Group {
            if let journey = navigationStore.state.route?.journey {
                VStack(spacing: 10) {
                    transitFreshnessIndicator(for: journey)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(journey.legs.enumerated()), id: \.element.id) { index, leg in
                        let tracking = transitProgress(for: leg)
                        let nextStopID = tracking?.nextStop?.stopID
                            ?? liveTransitDetails(for: leg)?.nextStops.first?.stopID
                        let upcomingStops = upcomingTransitStops(for: leg, at: Date(), tracking: tracking)
                        let stopsRemaining = tracking?.stopsUntilAlighting ?? upcomingStops.count
                        let isStopsExpanded = expandedTransitTimelineLegID == leg.id
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: transitLegSymbol(for: leg))
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                                .frame(width: 30, height: 30)
                                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                if leg.mode == "WALK" {
                                    Text("Idź do \(leg.to)")
                                        .font(.subheadline.weight(.semibold))
                                } else {
                                    HStack(spacing: 7) {
                                        Text(leg.line ?? "Komunikacja")
                                            .font(.caption.weight(.bold).monospacedDigit())
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 7).padding(.vertical, 4)
                                            .background(mapTransitColor(leg.lineColorHex ?? NaviAstraColorPalette.transitFallback),
                                                        in: RoundedRectangle(cornerRadius: 7))
                                        Text(leg.direction ?? leg.to)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                    }
                                    if let operatorName = leg.operatorName, !operatorName.isEmpty {
                                        Text(operatorName).font(.caption2).foregroundStyle(Color.naviTextSecondary)
                                    }
                                }
                                Text("\(transitLegTimeDescription(leg)) · \(leg.from) → \(leg.to)")
                                    .font(.caption).foregroundStyle(Color.naviTextSecondary)
                                if leg.mode != "WALK", !leg.transitStops.isEmpty {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            expandedTransitTimelineLegID = isStopsExpanded ? nil : leg.id
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(transitStopCountText(stopsRemaining))
                                            Image(systemName: isStopsExpanded ? "chevron.up" : "chevron.down")
                                                .font(.caption2.weight(.semibold))
                                        }
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.accentColor)
                                        .contentShape(Rectangle())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 2)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(isStopsExpanded
                                                        ? "Zwiń listę przystanków linii \(leg.line ?? "")"
                                                        : "Pokaż przystanki linii \(leg.line ?? "")")

                                    if isStopsExpanded {
                                        transitUpcomingStopsTimeline(
                                            leg,
                                            stops: upcomingStops,
                                            activeStopID: nextStopID ?? upcomingStops.first?.stopID)
                                            .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                                if let delay = displayedTransitDelay(for: leg), abs(delay) >= 30 {
                                    Text(delayLabel(TimeInterval(delay))).font(.caption.weight(.semibold))
                                        .foregroundStyle(transitDelayColor(delay))
                                } else if hasLiveTransitUpdate(for: leg) {
                                    Label("Na żywo", systemImage: "dot.radiowaves.left.and.right")
                                        .font(.caption2).foregroundStyle(Color.naviTextSecondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        if index < journey.legs.count - 1 {
                            Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 2, height: 9)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
                        }
                    }
                    ForEach(Array(journey.alerts.enumerated()), id: \.offset) { _, alert in
                        Label(alert, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(Color(naviHex: NaviAstraColorPalette.warning))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    func transitLegTimeDescription(_ leg: JourneyLeg) -> String {
        func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        let departure: String
        if let planned = leg.scheduledDeparture,
           abs(leg.departure.timeIntervalSince(planned)) >= 30 {
            departure = "\(time(planned)) plan. → \(time(leg.departure)) est."
        } else {
            departure = time(leg.departure)
        }
        let arrival: String
        if let planned = leg.scheduledArrival,
           abs(leg.arrival.timeIntervalSince(planned)) >= 30 {
            arrival = "\(time(planned)) plan. → \(time(leg.arrival)) est."
        } else {
            arrival = time(leg.arrival)
        }
        return "\(departure)–\(arrival)"
    }

    func transitLegSymbol(for leg: JourneyLeg) -> String {
        switch leg.mode.uppercased() {
        case "WALK": "figure.walk"
        case "TRAM": "tram.fill"
        case "SUBWAY", "METRO": "tram.fill"
        case "RAIL", "REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "SUBURBAN", "SUBURBAN_RAIL",
             "LONG_DISTANCE", "NIGHT_RAIL", "HIGHSPEED_RAIL": "train.side.front.car"
        case "FERRY": "ferry.fill"
        case "BIKE": "bicycle"
        default: "bus.fill"
        }
    }

    var parkRideJourneyTimeline: some View {
        Group {
            if let journey = navigationStore.state.route?.journey {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Etapy podróży")
                        .font(.subheadline.weight(.semibold))
                    transitFreshnessIndicator(for: journey)
                    if let headway = journey.frequencyEstimateHeadwaySeconds {
                        Label("Odjazdy orientacyjne co \(max(1, Int((Double(headway) / 60).rounded()))) min",
                              systemImage: "clock.badge.questionmark")
                            .font(.caption).foregroundStyle(Color.naviTextSecondary)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        metric(value: time(journey.arrival.timeIntervalSince(journey.departure)), caption: "całość")
                        if journey.walkingDuration > 0 {
                            metric(value: time(journey.walkingDuration), caption: "pieszo")
                        }
                        if journey.waitingDuration > 0 {
                            metric(value: time(journey.waitingDuration), caption: "oczekiwanie")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 0) {
                        ForEach(Array(journey.legs.enumerated()), id: \.element.id) { index, leg in
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: parkRideLegSymbol(leg.mode))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 30, height: 30)
                                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(parkRideLegTitle(leg))
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(leg.departure.formatted(date: .omitted, time: .shortened))–\(leg.arrival.formatted(date: .omitted, time: .shortened)) · \(time(max(0, leg.arrival.timeIntervalSince(leg.departure))))")
                                        .font(.caption)
                                        .foregroundStyle(Color.naviTextSecondary)
                                    Text(leg.from)
                                        .font(.caption)
                                        .foregroundStyle(Color.naviTextSecondary)
                                    if !leg.transitStops.isEmpty {
                                        Text("\(max(1, leg.transitStops.count - 1)) przystanków")
                                            .font(.caption2)
                                            .foregroundStyle(Color.naviTextSecondary)
                                    }
                                    if let delay = displayedTransitDelay(for: leg), abs(delay) >= 30 {
                                        Text(delayLabel(TimeInterval(delay)))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(transitDelayColor(delay))
                                    } else if hasLiveTransitUpdate(for: leg) {
                                        Label("Na żywo", systemImage: "dot.radiowaves.left.and.right")
                                            .font(.caption2)
                                            .foregroundStyle(Color.naviTextSecondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)

                            if leg.mode == "CAR" {
                                HStack(spacing: 9) {
                                    Image(systemName: "parkingsign.circle.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 30, height: 25)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Parking P+R · \(leg.to)")
                                            .font(.caption.weight(.semibold))
                                        Text("Koniec odcinka autem · przesiadka na komunikację")
                                            .font(.caption2)
                                            .foregroundStyle(Color.naviTextSecondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.leading, 1)
                                .padding(.vertical, 7)
                                .accessibilityElement(children: .combine)
                            }

                            if index < journey.legs.count - 1 {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(width: 2, height: 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 14)
                                    .padding(.vertical, 3)
                            }
                        }
                    }
                    ForEach(Array(journey.alerts.enumerated()), id: \.offset) { _, alert in
                        Label(alert, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color(naviHex: NaviAstraColorPalette.warning))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    func parkRideLegSymbol(_ mode: String) -> String {
        switch mode {
        case "CAR": "car.fill"
        case "WALK": "figure.walk"
        case "RAIL": "train.side.front.car"
        case "TRAM": "tram.fill"
        case "SUBWAY", "METRO": "tram.fill"
        case "FERRY": "ferry.fill"
        default: "bus.fill"
        }
    }

    func parkRideLegTitle(_ leg: JourneyLeg) -> String {
        switch leg.mode {
        case "CAR": "Samochodem do \(leg.to)"
        case "WALK": "Pieszo · \(leg.to)"
        case "RAIL": "\(leg.line ?? "Pociąg") · \(leg.to)"
        case "TRAM": "\(leg.line.flatMap { $0.isEmpty ? nil : $0 } ?? "Tramwaj") · \(leg.to)"
        case "SUBWAY", "METRO": "\(leg.line ?? "Metro") · \(leg.to)"
        case "FERRY": "\(leg.line ?? "Prom") · \(leg.to)"
        default: "\(leg.line ?? "Autobus") · \(leg.to)"
        }
    }

    var arrivalCard: some View {
#if os(iOS)
        arrivalSuccessCard
#else
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color(naviHex: NaviAstraColorPalette.success), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(arrivalTitle)
                        .font(.headline)
                    Text(navigationStore.state.destination?.name ?? "Podróż zakończona")
                        .font(.subheadline)
                        .foregroundStyle(Color.naviTextSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            if let trip = navigationStore.state.lastTrip {
                HStack(spacing: 0) {
                    metric(value: distance(trip.distanceMeters), caption: arrivalDistanceCaption)
                    Spacer()
                    metric(value: time(trip.duration), caption: "czas")
                    Spacer()
                    metric(value: arrivalSummaryMetric.value, caption: arrivalSummaryMetric.caption)
                }
                HStack(spacing: 0) {
                    metric(value: timeAllowingZero(trip.stoppedSeconds), caption: "postój")
                    Spacer()
                    metric(value: "\(trip.rerouteCount)", caption: "przeliczenia")
                    Spacer()
                    if let delay = trip.delaySeconds {
                        metric(value: delayLabel(delay), caption: "względem ETA")
                    } else {
                        metric(value: "—", caption: "względem ETA")
                    }
                }
            }

            arrivalDrivingScoreSummary

            arrivalParkedCarPrompt

            Button {
                navigationStore.stop()
            } label: {
                Text("Zamknij podsumowanie")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(17)
        .modifier(NavigationGlassSurface(radius: 25))
#endif
    }

    var arrivalSuccessCard: some View {
        let shape = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(topLeading: 32, bottomLeading: 0,
                                              bottomTrailing: 0, topTrailing: 32),
            style: .continuous)

        return VStack(spacing: 0) {
            Capsule()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 38, height: 4)
                .padding(.top, 8)

            ArrivalCelebration()
                .frame(height: 108)
                .padding(.top, 4)

            VStack(spacing: 5) {
                Text(arrivalTitle)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .foregroundStyle(Color.naviTextPrimary)
                Text(navigationStore.state.lastTrip?.destination.name ?? navigationStore.state.destination?.name ?? "Podróż zakończona")
                    .font(.subheadline)
                    .foregroundStyle(Color.naviTextSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .modifier(ArrivalSectionEntrance(delay: 0.12))

            HStack(spacing: 0) {
                arrivalMetric(symbol: navigationStore.state.transportMode.symbol,
                              value: navigationStore.state.lastTrip.map { distance($0.distanceMeters) } ?? "—",
                              caption: arrivalDistanceCaption)
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1, height: 34)
                arrivalMetric(symbol: "clock",
                              value: navigationStore.state.lastTrip.map { time($0.duration) } ?? "—",
                              caption: "czas")
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1, height: 34)
                arrivalMetric(symbol: arrivalSummaryMetric.symbol,
                              value: arrivalSummaryMetric.value,
                              caption: arrivalSummaryMetric.caption)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 14)
            .modifier(NavigationGlassSurface(radius: 19))
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .modifier(ArrivalSectionEntrance(delay: 0.22))

            arrivalDrivingScoreSummary
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .modifier(ArrivalSectionEntrance(delay: 0.30))

            arrivalParkedCarPrompt
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .modifier(ArrivalSectionEntrance(delay: 0.34))

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        if !isDestinationFavorite, let destination = navigationStore.state.destination {
                            addFavoriteWithFeedback(destination, failureToast: false)
                        }
                    } label: {
                        arrivalActionLabel(symbol: isDestinationFavorite ? "checkmark" : "star",
                                           title: isDestinationFavorite ? "Zapisano" : "Zapisz miejsce")
                    }
                    .buttonStyle(ArrivalActionButtonStyle())
                    .accessibilityLabel(isDestinationFavorite ? "Miejsce zapisane w ulubionych" : "Zapisz miejsce")

                    arrivalShareAction
                }

                Button {
                    navigationStore.stop()
                } label: {
                    arrivalActionLabel(symbol: "checkmark", title: "Zakończ", primary: true)
                }
                .buttonStyle(ArrivalActionButtonStyle())
                .accessibilityLabel("Zakończ nawigację")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 18)
            .modifier(ArrivalSectionEntrance(delay: 0.40))
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .modifier(NavigationGlassPanelSurface(shape: shape))
    }

    @ViewBuilder
    private var arrivalDrivingScoreSummary: some View {
        if let trip = navigationStore.state.lastTrip,
           trip.drivingScore != nil || (navigationStore.state.transportMode == .car && trip.arrived) {
            DrivingScoreSummaryCard(trip: trip)
        }
    }

    var arrivalShareAction: some View {
        Group {
            if let url = arrivalShareURL {
                ShareLink(item: url) {
                    arrivalActionLabel(symbol: "square.and.arrow.up", title: "Udostępnij trasę")
                }
            } else {
                arrivalActionLabel(symbol: "square.and.arrow.up", title: "Udostępnij trasę")
                    .opacity(0.55)
            }
        }
        .buttonStyle(ArrivalActionButtonStyle())
        .accessibilityLabel("Udostępnij trasę")
    }

    func arrivalMetric(symbol: String, value: String, caption: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.naviTextSecondary)
                .frame(height: 19)
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.naviTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(caption)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.naviTextSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    func arrivalActionLabel(symbol: String, title: String, primary: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 22)
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(primary ? Color.white : Color.naviTextPrimary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(primary ? Color.accentColor : Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(primary ? 0.12 : 0.08), lineWidth: 1)
        }
        .shadow(color: primary ? Color.accentColor.opacity(0.18) : .clear, radius: 10, y: 4)
    }
}
