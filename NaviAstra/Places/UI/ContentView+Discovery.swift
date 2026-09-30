import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

extension ContentView {
    var arLaunchReadinessTaskKey: String {
        let state = navigationStore.state
        let coordinate = state.location?.coordinate
        let latitudeBucket = coordinate.map { Int(($0.latitude * 100).rounded()) } ?? 0
        let longitudeBucket = coordinate.map { Int(($0.longitude * 100).rounded()) } ?? 0
        return "\(latitudeBucket):\(longitudeBucket):\(String(describing: state.gpsQuality)):\(state.route?.id.uuidString ?? "none"): \(state.progress?.nextManeuver?.id ?? -1)"
    }

    func discoveryPanel(compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            searchButton
            if !compact {
                HStack(alignment: .firstTextBaseline) {
                    Text("Ulubione")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Button("Zobacz wszystkie", systemImage: "heart") { appRouter.present(.favorites) }
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 44)
                }
                if !savedPlaceShortcuts.isEmpty {
                    quickDestinationShelf(savedPlaceShortcuts)
                } else {
                    Text("Zapisz Dom, Pracę lub ulubiony adres, aby mieć je zawsze pod ręką.")
                        .font(.subheadline)
                        .foregroundStyle(Color.naviTextSecondary)
                }

                Divider()
                Text("Szukaj w pobliżu")
                    .font(.headline.weight(.semibold))
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach([NearbyPlaceCategory.fuel, .charging, .parking, .food]) { category in
                            Button { presentNearby(category) } label: {
                                Label(category.title, systemImage: category.symbol)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 13)
                                    .frame(minHeight: 44)
                                    .background(Color.accentColor.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .scrollIndicators(.visible)
                .accessibilityLabel("Miejsca w pobliżu")

                HStack(alignment: .firstTextBaseline) {
                    Text("Ostatnie miejsca")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Button {
                        appRouter.present(.history)
                    } label: {
                        Label("Historia", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Historia podróży")
                }
                if !recentPlaceShortcuts.isEmpty {
                    VStack(spacing: 7) {
                        ForEach(recentPlaceShortcuts.prefix(3)) { shortcut in
                            recentPlaceRow(shortcut)
                        }
                    }
                } else {
                    Text("Ostatnio wybrane miejsca pojawią się tutaj.")
                        .font(.subheadline)
                        .foregroundStyle(Color.naviTextSecondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, compact ? 4 : 18)
    }

    @ViewBuilder
    var nearbyTransitCard: some View {
        if let stop = navigationStore.state.nearbyTransitStop,
           !navigationStore.state.nearbyTransitDepartures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { openTransitStop(stop) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "tram.fill").foregroundStyle(Color.accentColor)
                        Text("Transport w pobliżu").font(.subheadline.weight(.semibold)).foregroundStyle(Color.naviTextPrimary)
                        Spacer()
                        if let location = navigationStore.state.location?.coordinate {
                            Text(distance(location.distance(to: stop.coordinate)))
                                .font(.caption.monospacedDigit()).foregroundStyle(Color.naviTextSecondary)
                        }
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(stop.name).font(.caption).foregroundStyle(Color.naviTextSecondary).lineLimit(1)
                ForEach(navigationStore.state.nearbyTransitDepartures.prefix(3)) { departure in
                    Button { openTransitDeparture(departure) } label: {
                        TimelineView(.periodic(from: .now, by: 20)) { context in
                            HStack(spacing: 9) {
                                Text(departure.line).font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.white).frame(minWidth: 30, minHeight: 24)
                                    .background(mapTransitColor(departure.colorHex), in: RoundedRectangle(cornerRadius: 7))
                                Text(departure.destination).font(.caption.weight(.medium)).lineLimit(1)
                                Spacer(minLength: 3)
                                Text(transitETA(departure.estimatedDeparture, now: context.date))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(transitDelayColor(departure.delaySeconds))
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(13)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 17))
        }
    }

    func transitETA(_ departure: Date, now: Date) -> String {
        let minutes = Int(ceil(departure.timeIntervalSince(now) / 60))
        return minutes <= 0 ? "teraz" : time(TimeInterval(minutes * 60))
    }

    func transitDelayColor(_ seconds: Int?) -> Color {
        guard let seconds else { return .primary }
        guard seconds > 0 else { return .secondary }
        let minutes = seconds / 60
        if minutes > 5 { return Color(naviHex: NaviAstraColorPalette.danger) }
        if minutes >= 3 { return Color(naviHex: NaviAstraColorPalette.warning) }
        return .primary
    }

    func quickDestinationShelf(_ shortcuts: [PlaceShortcut]) -> some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(shortcuts) { shortcut in
                            Button {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                                    selectDestination(shortcut.destination)
                                }
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: shortcut.symbol)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 20)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(shortcut.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Color.naviTextPrimary)
                                            .lineLimit(1)
                                        if let estimatedMinutes = shortcut.estimatedMinutes {
                                            let routeDistance = shortcut.estimatedDistanceMeters.map(distance)
                                            Text(routeDistance.map { "\(estimatedMinutes) min · \($0)" } ?? "\(estimatedMinutes) min")
                                                .font(.caption.weight(.medium).monospacedDigit())
                                                .foregroundStyle(Color.naviTextSecondary)
                                        }
                                    }
                                }
                                .padding(.horizontal, 13)
                                .frame(minWidth: 112, minHeight: 54, alignment: .leading)
                                .background(Color.primary.opacity(0.045), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.045)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Pokaż miejsce \(shortcut.title)")
                            .accessibilityHint(shortcut.isRecent ? "Ostatnio wybrane miejsce" : "Zapisane miejsce")
                            .id(shortcut.id)
                        }
                    }
                    .padding(.leading, 7)
                    .padding(.trailing, shortcuts.count > 2 ? 10 : 7)
                }
                .scrollIndicators(.hidden)
                .mask(LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.82),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing))

                if shortcuts.count > 2, let lastShortcut = shortcuts.last {
                    Button {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            proxy.scrollTo(lastShortcut.id, anchor: .trailing)
                        }
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.naviTextSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pokaż kolejne miejsca")
                }
            }
            .padding(.vertical, 4)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentPlaceRow(_ shortcut: RecentPlaceShortcut) -> some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                selectDestination(shortcut.destination)
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text(shortcut.destination.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.naviTextPrimary)
                        .lineLimit(1)
                    Text(shortcut.destination.address ?? "Ostatnio wybrane miejsce")
                        .font(.caption)
                        .foregroundStyle(Color.naviTextSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(recentPlaceTime(shortcut.usedAt, relativeTo: context.date))
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(Color.naviTextSecondary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Otwórz ostatnie miejsce: \(shortcut.destination.name)")
        .accessibilityHint(shortcut.destination.address ?? "Ostatnio wybrane miejsce")
    }

    private func recentPlaceTime(_ date: Date, relativeTo now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        let totalMinutes = Int(abs(elapsed) / 60)
        guard totalMinutes > 0 else { return "teraz" }

        let value = totalMinutes < 60 ? "\(totalMinutes) min" : "\(totalMinutes / 60) godz."
        return elapsed >= 0 ? "\(value) temu" : "za \(value)"
    }

    func voiceSliderRow(title: String, value: Binding<Double>,
                                range: ClosedRange<Double>, valueDescription: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(valueDescription)
                    .foregroundStyle(Color.naviTextSecondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    func mapControl(compact: Bool) -> some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
        return HStack(alignment: .bottom) {
#if os(macOS)
            if isNavigating && isOnRoadDrivingLeg {
                VStack(alignment: .leading, spacing: 8) {
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        speedCard(at: context.date)
                    }
                    navigationTrafficIncidentBanner
                    navigationRoadDataFooter
                }
            }
#endif
            Spacer()
            layout {
                if isNavigating {
#if os(iOS)
                    if navigationStore.state.transportMode == .walking {
                        Button {
                            isARNavigationPresented = true
                        } label: {
                            circleSurface {
                                Image(systemName: "viewfinder")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .overlay {
                                Circle()
                                    .stroke(arLaunchReadiness.color, lineWidth: 3)
                                    .padding(-3)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Otwórz nawigację AR")
                        .accessibilityHint(arLaunchReadiness.explanation)
                        .task(id: arLaunchReadinessTaskKey) {
                            arLaunchReadiness = .checking
                            let readiness = await ARLaunchReadinessChecker.check(
                                location: navigationStore.state.location,
                                route: navigationStore.state.route,
                                progress: navigationStore.state.progress)
                            guard !Task.isCancelled else { return }
                            arLaunchReadiness = readiness
                        }
                    }
#endif
                    Button {
                        navigationStore.setVoiceEnabled(!navigationStore.state.voiceEnabled)
                    } label: {
                        circleSurface {
                            Image(systemName: navigationStore.state.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(navigationStore.state.voiceEnabled ? Color.accentColor : Color.naviTextSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(navigationStore.state.voiceEnabled ? "Wyłącz komunikaty głosowe" : "Włącz komunikaty głosowe")
                } else {
                    mapLayersMenu
                }
                Button {
                    if isNavigating {
                        navigationStore.returnToFollow()
                    } else if navigationStore.state.cameraState == .routeOverview {
                        navigationStore.returnToFollow()
                    } else if navigationStore.state.route != nil {
                        navigationStore.showRouteOverview()
                    } else {
                        navigationStore.returnToFollow()
                    }
                } label: {
                    circleSurface {
                        Image(systemName: isNavigating ? "location.north.fill"
                              : navigationStore.state.cameraState == .routeOverview ? "location.fill" : "scope")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.naviTextPrimary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(isNavigating ? "Wróć do nawigacji" : "Moja pozycja", systemImage: "location.fill") {
                        navigationStore.returnToFollow()
                    }
                    Button("Tu zaparkowałem", systemImage: "car.side.fill", action: saveCurrentParkedCar)
                        .disabled(currentParkedCarLocation == nil)
                    if navigationStore.state.route != nil {
                        Button("Cała trasa", systemImage: "map") {
                            navigationStore.showRouteOverview()
                        }
                    }
                }
                .accessibilityLabel(isNavigating
                    ? "Wróć do prowadzenia"
                    : (navigationStore.state.route == nil ? "Moja pozycja" : (navigationStore.state.cameraState == .routeOverview ? "Wróć do mapy" : "Przegląd trasy")))
                .accessibilityHint(isNavigating
                    ? "Ustawia kamerę na bieżącej pozycji i kierunku podróży"
                    : "Przełącza między mapą i przeglądem trasy")
            }
        }
    }
}
