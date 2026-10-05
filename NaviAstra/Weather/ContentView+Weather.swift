import SwiftUI

extension ContentView {
    var weatherConfiguration: WeatherVisualConfiguration {
        WeatherVisualEngine.configuration(state: weatherStore.current, intensity: weatherIntensity,
                                          animations: weatherAnimations && !ProcessInfo.processInfo.isLowPowerModeEnabled, colors: weatherMapColors,
                                          duringNavigation: weatherDuringNavigation, navigating: isNavigating,
                                          reduceMotion: reduceMotion)
    }

    var weatherRequestKey: String {
        let location = navigationStore.state.location?.coordinate
        let latitude = Int(((location?.latitude ?? 0) * 20).rounded())
        let longitude = Int(((location?.longitude ?? 0) * 20).rounded())
        return "\(scenePhase == .active)-\(weatherEnabled)-\(weatherRouteForecast)-\(latitude)-\(longitude)-\(location != nil)-\(navigationStore.state.route?.id.uuidString ?? "none")-\(isNavigating)-\(navigationStore.state.journeyTimeMode)-\(navigationStore.state.journeyTargetTime.timeIntervalSince1970)"
    }

    func updateWeather() async {
        guard weatherEnabled else { weatherStore.clear(); return }
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            let state = navigationStore.state
            let departure: Date
            if !isNavigating && state.journeyTimeMode != .now {
                departure = state.journeyTimeMode == .arriveBy
                    ? state.journeyTargetTime.addingTimeInterval(-(state.route?.expectedTravelTime ?? 0))
                    : state.journeyTargetTime
            } else { departure = Date() }
            await weatherStore.refresh(location: state.location?.coordinate, route: weatherRouteForecast ? state.route : nil,
                                       progress: isNavigating ? state.routeGeometryProgress : 0,
                                       remainingTime: isNavigating ? state.progress?.remainingTime : nil,
                                       departure: max(Date(), departure))
            do { try await Task.sleep(for: .seconds(600)) } catch { return }
        }
    }

    var visibleWeatherSamples: [RouteWeatherSample] {
        guard weatherEnabled, weatherRouteForecast, weatherStore.routeID == navigationStore.state.route?.id,
              let date = weatherStore.updatedAt, Date().timeIntervalSince(date) < 1800 else { return [] }
        return weatherStore.samples.filter { $0.weather.condition.isHazard }
    }

    private var upcomingWeatherSample: RouteWeatherSample? {
        let state = navigationStore.state
        let position = (isNavigating ? state.routeGeometryProgress : 0) *
            (state.route.map { RouteGeometrySplitter.length(of: $0.coordinates) } ?? 0)
        return visibleWeatherSamples.first { $0.endDistance > position }
    }

    private var weatherControlState: WeatherVisualState? {
        upcomingWeatherSample?.weather ?? weatherStore.current
    }

    private var weatherNoticeText: String {
        let state = navigationStore.state
        return (weatherRouteForecast
            ? weatherStore.upcoming(progress: isNavigating ? state.routeGeometryProgress : 0,
                                    route: state.route, remainingTime: state.progress?.remainingTime) : nil)
            ?? weatherStore.current?.condition.title ?? weatherStore.status
    }

    private var weatherDistanceLabel: String? {
        guard let sample = upcomingWeatherSample else { return nil }
        let state = navigationStore.state
        let position = (isNavigating ? state.routeGeometryProgress : 0) *
            (state.route.map { RouteGeometrySplitter.length(of: $0.coordinates) } ?? 0)
        let meters = max(0, sample.startDistance - position)
        if meters < 500 { return "Tutaj" }
        return "~\(max(1, Int((meters / 1000).rounded()))) km"
    }

    @ViewBuilder var weatherMapControl: some View {
        if weatherEnabled {
            Button { showsWeatherDetails = true } label: {
                circleSurface {
                    VStack(spacing: 0) {
                        WeatherIcon(state: weatherControlState, size: weatherDistanceLabel == nil ? 34 : 28)
                        if let label = weatherDistanceLabel {
                            Text(label)
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.naviTextSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pogoda: \(weatherNoticeText)")
            .accessibilityHint("Pokaż szczegóły pogody")
            .popover(isPresented: $showsWeatherDetails) {
                weatherDetails
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var weatherDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                WeatherIcon(state: weatherControlState, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(upcomingWeatherSample == nil ? "Pogoda w okolicy" : "Pogoda na trasie")
                        .font(.headline)
                    Text(weatherControlState?.condition.title ?? "Brak danych")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text(weatherNoticeText)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if upcomingWeatherSample != nil, let current = weatherStore.current {
                HStack(spacing: 6) {
                    WeatherIcon(state: current, size: 22)
                    Text("Teraz w okolicy: \(current.condition.title)").font(.caption)
                }
            }
            if let updatedAt = weatherStore.updatedAt {
                Text("Aktualizacja: \(updatedAt.formatted(date: .omitted, time: .shortened)) · prognoza")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 270, alignment: .leading)
    }

    var settingsWeatherSection: some View {
        Section {
            Toggle("Pogoda na mapie", isOn: $weatherEnabled)
            if weatherEnabled {
                Picker("Intensywność efektów", selection: $weatherIntensity) {
                    ForEach(WeatherEffectIntensity.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Animacje pogodowe", isOn: $weatherAnimations)
                Toggle("Dopasowanie kolorów mapy", isOn: $weatherMapColors)
                Toggle("Efekty podczas nawigacji", isOn: $weatherDuringNavigation)
                Toggle("Prognoza na trasie", isOn: $weatherRouteForecast)
                Text(weatherStore.status).font(.footnote).foregroundStyle(.secondary)
                Link("Dane pogodowe: Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                Link("Ikony: Meteocons · Bas Milius · MIT",
                     destination: URL(string: "https://github.com/basmilius/meteocons")!)
                DisclosureGroup("Licencja ikon pogodowych") {
                    Text(WeatherIconLicense.text)
                        .font(.caption).textSelection(.enabled)
                }
            }
        } header: { Text("Efekty pogodowe · automatyczne")
        } footer: {
            Text("Prognoza korzysta z lokalizacji i maksymalnie 12 punktów trasy wysyłanych do Open-Meteo. Kolorowe odcinki pokazują przybliżone warunki w czasie przejazdu, nie granice opadów ani radar. Podczas nawigacji efekty są ograniczone, a błyski wyłączone.")
        }
    }
}
