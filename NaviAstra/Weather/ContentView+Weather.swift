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

    @ViewBuilder var weatherMapNotice: some View {
        if weatherEnabled {
            let state = navigationStore.state
            let message = weatherRouteForecast
                ? weatherStore.upcoming(progress: isNavigating ? state.routeGeometryProgress : 0,
                                        route: state.route, remainingTime: state.progress?.remainingTime) : nil
            let position = (isNavigating ? state.routeGeometryProgress : 0) *
                (state.route.map { RouteGeometrySplitter.length(of: $0.coordinates) } ?? 0)
            let upcomingSymbol = visibleWeatherSamples.first(where: { $0.endDistance > position })?.weather.condition.symbol
            HStack(spacing: 8) {
                Image(systemName: (message != nil ? upcomingSymbol : weatherStore.current?.condition.symbol) ?? "cloud")
                Text(message ?? weatherStore.current.map { "\($0.condition.title)" } ?? weatherStore.status)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
        }
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
            }
        } header: { Text("Efekty pogodowe · automatyczne")
        } footer: {
            Text("Prognoza korzysta z lokalizacji i maksymalnie 12 punktów trasy wysyłanych do Open-Meteo. Kolorowe odcinki pokazują przybliżone warunki w czasie przejazdu, nie granice opadów ani radar. Podczas nawigacji efekty są ograniczone, a błyski wyłączone.")
        }
    }
}
