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
                    VStack(spacing: 1) {
                        WeatherIcon(state: weatherControlState, size: weatherDistanceLabel == nil ? 34 : 27,
                                    showsBackground: false)
                        if let label = weatherDistanceLabel {
                            Text(label)
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                WeatherIcon(state: weatherControlState, size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(upcomingWeatherSample == nil ? "Pogoda w okolicy" : "Pogoda na trasie")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.naviTextSecondary)
                    Text(weatherControlState?.condition.title ?? "Brak danych")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.naviTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let distance = weatherDistanceLabel {
                    Label(distance == "Tutaj" ? "Na tym odcinku" : "Za \(distance)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(weatherNoticeText)
                    .font(.subheadline)
                    .foregroundStyle(Color.naviTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let state = weatherControlState {
                HStack(alignment: .top, spacing: 10) {
                    weatherMetric("Opady", symbol: "drop", value: "\(weatherNumber(state.precipitation)) mm")
                    weatherMetric("Wiatr", symbol: "wind", value: "\(weatherNumber(state.windSpeed * 3.6)) km/h")
                }
                HStack(spacing: 8) {
                    Image(systemName: "eye")
                        .foregroundStyle(Color.naviTextSecondary)
                    Text("Widoczność")
                        .foregroundStyle(Color.naviTextSecondary)
                    Spacer(minLength: 4)
                    Text(weatherVisibilityLabel(state.visibility))
                        .fontWeight(.medium)
                        .foregroundStyle(Color.naviTextPrimary)
                }
                .font(.caption)
            }

            if upcomingWeatherSample != nil, let current = weatherStore.current {
                HStack(spacing: 8) {
                    WeatherIcon(state: current, size: 26, showsBackground: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Teraz w okolicy").foregroundStyle(Color.naviTextSecondary)
                        Text(current.condition.title).fontWeight(.medium)
                    }
                    .font(.caption)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }

            Divider().opacity(0.6)
            if let updatedAt = weatherStore.updatedAt {
                Label("Aktualizacja \(updatedAt.formatted(date: .omitted, time: .shortened)) · prognoza",
                      systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(Color.naviTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(weatherStore.status)
                    .font(.caption2)
                    .foregroundStyle(Color.naviTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 300, alignment: .leading)
    }

    private func weatherMetric(_ title: String, symbol: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(Color.naviTextSecondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.naviTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }

    private func weatherNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func weatherVisibilityLabel(_ meters: Double?) -> String {
        guard let meters else { return "Brak danych" }
        return meters >= 1000 ? "\(weatherNumber(meters / 1000)) km" : "\(Int(meters.rounded())) m"
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
