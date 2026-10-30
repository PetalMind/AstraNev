#if os(iOS)
import SwiftUI

extension ContentView {
    func drivingMapControls(at date: Date) -> some View {
        ViewThatFits(in: .horizontal) {
            drivingMapControlsRow(at: date, condensed: false)
            drivingMapControlsRow(at: date, condensed: true)

            VStack(spacing: 8) {
                HStack {
                    speedCard(at: date, compact: true, condensed: true)
                        .fixedSize()
                    Spacer(minLength: 8)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    mapTools(compact: true, controlSize: 44, showsParkedCar: false)
                    mapPositionControl(size: 44)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func drivingMapControlsRow(at date: Date, condensed: Bool) -> some View {
        let controlSize: CGFloat = condensed ? 44 : 48

        return HStack(alignment: .center, spacing: condensed ? 4 : 8) {
            speedCard(at: date, compact: true, condensed: condensed)
                .fixedSize()
                .layoutPriority(1)
            Spacer(minLength: 0)
            mapTools(compact: true, controlSize: controlSize, showsParkedCar: false)
                .fixedSize()
            mapPositionControl(size: condensed ? 44 : 56)
        }
    }

    func mapControl(compact: Bool) -> some View {
        let layout = compact
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 10))
            : AnyLayout(VStackLayout(alignment: .center, spacing: 14))

        return HStack(alignment: .bottom) {
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                layout {
                    if !isNavigating { weatherMapControl }
                    mapTools(compact: compact)
                    mapPositionControl
                }
                .fixedSize()

                if compact {
                    VStack(alignment: .trailing, spacing: 10) {
                        mapTools(compact: true)
                        HStack(spacing: 10) {
                            if !isNavigating { weatherMapControl }
                            mapPositionControl
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }

    private func mapTools(compact: Bool, controlSize: CGFloat = 48, showsParkedCar: Bool = true) -> some View {
        let layout = compact
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))

        return layout {
            Menu { mapLayerMenuActions } label: {
                mapToolLabel(symbol: "square.3.layers.3d", size: controlSize)
            }
            .accessibilityLabel("Wygląd i warstwy mapy")

            if showsParkedCar && placeStore.parkedCar != nil {
                mapToolDivider(compact: compact, controlSize: controlSize)
                Button { openParkedCarDetails() } label: {
                    mapToolLabel(symbol: "car.side.fill", size: controlSize)
                }
                .accessibilityLabel("Zaparkowany samochód")
                .accessibilityHint("Pokaż zapisane miejsce i trasę pieszą do auta")
            }

            if isNavigating {
                if navigationStore.state.transportMode == .walking {
                    mapToolDivider(compact: compact, controlSize: controlSize)
                    mapARNavigationControl
                }
                mapToolDivider(compact: compact, controlSize: controlSize)
                Button {
                    navigationStore.setVoiceEnabled(!navigationStore.state.voiceEnabled)
                } label: {
                    mapToolLabel(
                        symbol: navigationStore.state.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                        secondary: !navigationStore.state.voiceEnabled, size: controlSize)
                }
                .accessibilityLabel(navigationStore.state.voiceEnabled
                    ? "Wyłącz komunikaty głosowe" : "Włącz komunikaty głosowe")
                .accessibilityValue(navigationStore.state.voiceEnabled ? "Włączone" : "Wyłączone")
            }

            mapToolDivider(compact: compact, controlSize: controlSize)
            VoiceAssistantButton(assistant: voiceAssistant, controlSize: controlSize)
        }
        .buttonStyle(.plain)
        .modifier(NavigationGlassSurface(radius: 24))
    }

    private func mapToolDivider(compact: Bool, controlSize: CGFloat = 48) -> some View {
        Rectangle()
            .fill(Color.naviTextSecondary.opacity(0.2))
            .frame(width: compact ? 1 : 24, height: compact ? 24 : 1)
            .frame(width: compact ? 1 : controlSize, height: compact ? controlSize : 1)
            .accessibilityHidden(true)
    }

    func mapToolLabel(symbol: String, secondary: Bool = false, size: CGFloat = 48) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(secondary ? Color.naviTextSecondary : Color.naviTextPrimary)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
    }

    private var mapARNavigationControl: some View {
        Button {
            isARNavigationPresented = true
        } label: {
            mapToolLabel(symbol: "viewfinder")
                .overlay(alignment: .bottom) {
                    Circle()
                        .fill(arLaunchReadiness.color)
                        .frame(width: 5, height: 5)
                        .padding(.bottom, 5)
                        .accessibilityHidden(true)
                }
        }
        .accessibilityLabel("Otwórz nawigację AR")
        .accessibilityHint(arLaunchReadiness.explanation)
        .task(id: arLaunchReadinessTaskKey) {
            arLaunchReadiness = .checking
            while !Task.isCancelled {
                arLaunchReadiness = await ARLaunchReadinessChecker.check(
                    location: navigationStore.state.location,
                    route: navigationStore.state.route,
                    progress: navigationStore.state.progress)
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private var mapPositionControl: some View {
        mapPositionControl(size: 56)
    }

    private func mapPositionControl(size: CGFloat) -> some View {
        Button {
            if isNavigating || navigationStore.state.cameraState == .routeOverview {
                navigationStore.returnToFollow()
            } else if navigationStore.state.route != nil {
                navigationStore.showRouteOverview()
            } else {
                navigationStore.returnToFollow()
            }
        } label: {
            Image(systemName: isNavigating ? "location.north.fill"
                  : navigationStore.state.cameraState == .routeOverview ? "location.fill" : "scope")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color.accentColor, in: Circle())
                .contentShape(Circle())
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(isNavigating ? "Wróć do nawigacji" : "Moja pozycja", systemImage: "location.fill") {
                navigationStore.returnToFollow()
            }
            Button("Tu zaparkowałem", systemImage: "car.side.fill", action: saveCurrentParkedCar)
                .disabled(currentParkedCarLocation == nil)
            if placeStore.parkedCar != nil {
                Button("Zaparkowany samochód", systemImage: "car.side.fill") {
                    openParkedCarDetails()
                }
            }
            if navigationStore.state.route != nil {
                Button("Cała trasa", systemImage: "map") {
                    navigationStore.showRouteOverview()
                }
            }
        }
        .accessibilityLabel(isNavigating
            ? "Wróć do prowadzenia"
            : (navigationStore.state.route == nil ? "Moja pozycja"
               : (navigationStore.state.cameraState == .routeOverview ? "Wróć do mapy" : "Przegląd trasy")))
        .accessibilityHint(isNavigating
            ? "Ustawia kamerę na bieżącej pozycji i kierunku podróży"
            : "Przełącza między mapą i przeglądem trasy")
    }
}
#endif
