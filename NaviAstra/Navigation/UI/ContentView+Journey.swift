import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

extension ContentView {
    var journeyPanel: some View {
#if os(iOS)
        journeyNavigationPanel
#else
        desktopJourneyPanel
#endif
    }

    var journeyNavigationPanel: some View {
        let shape = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(topLeading: 42, bottomLeading: 0,
                                              bottomTrailing: 0, topTrailing: 42),
            style: .continuous)

        return VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.48))
                .frame(width: 38, height: 4)
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                    if value.translation.height < -35 {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { navigationPanelExpanded = true }
                    } else if value.translation.height > 35 {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { navigationPanelExpanded = false }
                    }
                })
                .padding(.top, 8)
                .padding(.bottom, 12)

            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    navigationPanelExpanded.toggle()
                }
            } label: {
                HStack(spacing: 0) {
                    journeySummaryMetric(value: time(navigationStore.state.progress?.remainingTime ?? 0), caption: "do celu")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    journeySummaryMetric(value: distance(navigationStore.state.progress?.remainingDistance ?? 0), caption: "pozostało")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    journeySummaryMetric(value: arrivalTime(navigationStore.state.progress?.remainingTime ?? 0), caption: navigationArrivalCaption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: navigationPanelExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.66))
                        .padding(.leading, 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .accessibilityLabel(navigationPanelExpanded ? "Zwiń panel prowadzenia" : "Rozwiń panel prowadzenia")

            if navigationStore.state.transportMode == .transit, let transitLeg = activeTransitLeg {
                Group {
                    if transitLeg.mode == "WALK" {
                        transitWalkNavigationCard(transitLeg)
                    } else {
                        transitNavigationCard(transitLeg)
                    }
                }
                .padding(.top, 16)
            } else {
                journeyDestinationRow
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
            }

            HStack(spacing: 8) {
                journeyFooterAction(symbol: "arrow.triangle.branch", title: "Przegląd\ntrasy") {
                    navigationStore.showRouteOverview()
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        navigationPanelExpanded = false
                    }
                }
                journeyFooterAction(symbol: "stop.circle.fill", title: "Zakończ\nnawigację", destructive: true) {
                    navigationStore.stop()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 15)

            if navigationPanelExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Rectangle()
                        .fill(Color.white.opacity(0.11))
                        .frame(height: 1)
                    Text("W trakcie podróży")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    journeyActionsGrid

                    if navigationStore.state.transportMode == .transit {
                        transitJourneyTimeline
                    } else if navigationStore.state.transportMode == .parkRide {
                        parkRideJourneyTimeline
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .modifier(NavigationGlassPanelSurface(shape: shape))
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
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .modifier(NavigationGlassSurface(radius: 18))
        .accessibilityElement(children: .combine)
    }

    func journeySummaryMetric(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(caption)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.56))
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    func journeyFooterAction(symbol: String, title: String, destructive: Bool = false,
                                     action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(destructive ? Color.red : Color.white.opacity(0.67))
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding(.horizontal, 7)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(destructive ? Color.red.opacity(0.1) : Color.white.opacity(0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(destructive ? Color.red.opacity(0.24) : Color.white.opacity(0.08), lineWidth: 1)
            }
            .modifier(NavigationGlassSurface(radius: 18, interactive: true))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.replacingOccurrences(of: "\n", with: " "))
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
            if supportsActiveTripWaypoints {
                Button {
                    addingWaypoint = true
                    appRouter.present(.search)
                } label: {
                    journeyActionLabel("Przystanek", symbol: "plus.circle")
                }
                .disabled(navigationStore.state.waypoints.count >= 8)
            }
            #if os(macOS)
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
                        .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
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
                        .foregroundStyle(.red)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
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
            .foregroundStyle(.primary)
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
        case .live: ("dot.radiowaves.left.and.right", Color.green)
        case .degraded: ("clock.badge.exclamationmark", Color.orange)
        case .stale: ("clock", Color.secondary)
        case .unavailable: ("minus.circle", Color.secondary)
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
            if let leg = nextRide, let tripID = leg.tripID,
               let serviceDate = leg.serviceDate, let sequence = leg.transitStops.first?.sequence {
                let tripDetails = await transitStore.tripDetails(
                    tripID: tripID, serviceDate: serviceDate, fromStopSequence: sequence)
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
                        Text("Pieszo · około \(remaining) min").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let nextRide {
                        Text(nextRide.departure.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let nextRide {
                    HStack(spacing: 7) {
                        Text(nextRide.line ?? "MPK").font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4)
                            .background(mapTransitColor(nextRide.lineColorHex ?? 0x2867B2), in: RoundedRectangle(cornerRadius: 7))
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
                        .background(mapTransitColor(leg.lineColorHex ?? 0x2867B2), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(leg.to).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(minutesUntilDeparture > 0
                             ? "Odjazd za \(transitETA(leg.departure, now: context.date))"
                             : "W podróży · do \(leg.to)")
                            .font(.caption).foregroundStyle(.secondary)
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
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let delay = displayedDelay, abs(delay) >= 30 {
                    Text("Rozkład \(leg.departure.formatted(date: .omitted, time: .shortened)) · \(delayLabel(TimeInterval(delay)))")
                        .font(.caption).foregroundStyle(transitDelayColor(delay))
                } else if liveDetails?.nextStops.first?.hasRealtime == true {
                    Label("Aktualizacja na żywo", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.secondary)
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
            }

            if stops.isEmpty {
                Text("Brak kolejnych przystanków w danych trasy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                                .foregroundStyle(isNextStop ? .primary : .secondary)
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
                            .foregroundStyle(.secondary)
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
                            Image(systemName: leg.mode == "WALK" ? "figure.walk"
                                : leg.mode == "RAIL" ? "train.side.front.car"
                                : leg.mode == "TRAM" ? "tram.fill" : "bus.fill")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                                .frame(width: 30, height: 30)
                                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(leg.mode == "WALK" ? "Idź do \(leg.to)" : "\(leg.line ?? "MPK") · \(leg.to)")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(leg.departure.formatted(date: .omitted, time: .shortened)) · \(leg.from)")
                                    .font(.caption).foregroundStyle(.secondary)
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
                                        .font(.caption2).foregroundStyle(.secondary)
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
                            .font(.caption).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    var parkRideJourneyTimeline: some View {
        Group {
            if let journey = navigationStore.state.route?.journey {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Etapy podróży")
                        .font(.subheadline.weight(.semibold))
                    transitFreshnessIndicator(for: journey)
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
                                        .foregroundStyle(.secondary)
                                    Text(leg.from)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !leg.transitStops.isEmpty {
                                        Text("\(max(1, leg.transitStops.count - 1)) przystanków")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let delay = displayedTransitDelay(for: leg), abs(delay) >= 30 {
                                        Text(delayLabel(TimeInterval(delay)))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(transitDelayColor(delay))
                                    } else if hasLiveTransitUpdate(for: leg) {
                                        Label("Na żywo", systemImage: "dot.radiowaves.left.and.right")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
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
                                            .foregroundStyle(.secondary)
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
                            .foregroundStyle(.orange)
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
        default: "bus.fill"
        }
    }

    func parkRideLegTitle(_ leg: JourneyLeg) -> String {
        switch leg.mode {
        case "CAR": "Samochodem do \(leg.to)"
        case "WALK": "Pieszo · \(leg.to)"
        case "RAIL": "\(leg.line ?? "Pociąg") · \(leg.to)"
        case "TRAM": "\(leg.line.flatMap { $0.isEmpty ? nil : $0 } ?? "Tramwaj") · \(leg.to)"
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
                    .background(Color.green, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(arrivalTitle)
                        .font(.headline)
                    Text(navigationStore.state.destination?.name ?? "Podróż zakończona")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
            cornerRadii: RectangleCornerRadii(topLeading: 44, bottomLeading: 0,
                                              bottomTrailing: 0, topTrailing: 44),
            style: .continuous)

        return VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.48))
                .frame(width: 38, height: 4)
                .padding(.top, 8)

            ArrivalCelebration()
                .frame(height: 91)
                .padding(.top, 1)

            VStack(spacing: 2) {
                Text(arrivalTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(navigationStore.state.lastTrip?.destination.name ?? navigationStore.state.destination?.name ?? "Podróż zakończona")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)
            }
            .padding(.top, -3)

            HStack(spacing: 0) {
                arrivalMetric(symbol: navigationStore.state.transportMode.symbol,
                              value: navigationStore.state.lastTrip.map { distance($0.distanceMeters) } ?? "—",
                              caption: arrivalDistanceCaption)
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 1, height: 45)
                arrivalMetric(symbol: "clock",
                              value: navigationStore.state.lastTrip.map { time($0.duration) } ?? "—",
                              caption: "czas")
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 1, height: 45)
                arrivalMetric(symbol: arrivalSummaryMetric.symbol,
                              value: arrivalSummaryMetric.value,
                              caption: arrivalSummaryMetric.caption)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 76)
            .modifier(NavigationGlassSurface(radius: 19))
            .padding(.horizontal, 16)
            .padding(.top, 10)

            arrivalParkedCarPrompt
                .padding(.horizontal, 16)
                .padding(.top, 9)

            HStack(spacing: 7) {
                Button {
                    if !isDestinationFavorite, let destination = navigationStore.state.destination {
                        placeStore.add(destination, kind: .favorite)
                    }
                } label: {
                    arrivalActionLabel(symbol: isDestinationFavorite ? "checkmark" : "star",
                                       title: isDestinationFavorite ? "Zapisano" : "Zapisz\nmiejsce")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isDestinationFavorite ? "Miejsce zapisane w ulubionych" : "Zapisz miejsce")

                arrivalShareAction

                Button {
                    navigationStore.stop()
                } label: {
                    arrivalActionLabel(symbol: "paperplane.fill", title: "Zakończ", primary: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zakończ nawigację")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .modifier(NavigationGlassPanelSurface(shape: shape))
    }

    var arrivalShareAction: some View {
        Group {
            if let url = arrivalShareURL {
                ShareLink(item: url) {
                    arrivalActionLabel(symbol: "square.and.arrow.up", title: "Udostępnij\ntrasę")
                }
            } else {
                arrivalActionLabel(symbol: "square.and.arrow.up", title: "Udostępnij\ntrasę")
                    .opacity(0.55)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Udostępnij trasę")
    }

    func arrivalMetric(symbol: String, value: String, caption: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(height: 19)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(caption)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.56))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    func arrivalActionLabel(symbol: String, title: String, primary: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 22)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 55)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(primary ? Color(red: 0.05, green: 0.49, blue: 0.97) : Color.white.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(primary ? 0.12 : 0.08), lineWidth: 1)
        }
        .modifier(NavigationGlassSurface(radius: 18, interactive: true))
    }
}
