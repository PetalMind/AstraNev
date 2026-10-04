import Foundation
import Observation

struct RouteWeatherSample: Identifiable, Equatable {
    var id: Int { index }
    let index: Int
    let startDistance: Double
    let endDistance: Double
    let sampleDistance: Double
    let coordinates: [Coordinate]
    let weather: WeatherVisualState
}

@MainActor @Observable
final class WeatherStore {
    var current: WeatherVisualState?
    var samples: [RouteWeatherSample] = []
    var routeID: UUID?
    var updatedAt: Date?
    var status = "Pogoda oczekuje na lokalizację"
    @ObservationIgnored private let provider: any WeatherProviding

    init(provider: any WeatherProviding = OpenMeteoWeatherProvider()) { self.provider = provider }

    func clear() {
        current = nil; samples = []; routeID = nil; updatedAt = nil
        status = "Pogoda jest wyłączona"
    }

    func refresh(location: Coordinate?, route: NavigationRoute?, progress: Double,
                 remainingTime: TimeInterval?, departure: Date) async {
        if routeID != route?.id { samples = []; routeID = route?.id }
        // Never keep current weather from a previous geographic region while loading.
        current = nil
        guard let location else {
            samples = []; status = "Pogoda niedostępna — brak lokalizacji"; return
        }
        status = "Pobieranie pogody…"
        let length = route.map { RouteGeometrySplitter.length(of: $0.coordinates) } ?? 0
        let start = min(length, max(0, progress * length))
        let remaining = max(0, length - start)
        let count = route == nil || remaining < 100 ? 0 : min(12, max(2, Int(ceil(remaining / 15000)) + 1))
        let distances = (0..<count).map { start + remaining * Double($0) / Double(count - 1) }
        let points = distances.compactMap { distance in
            route.flatMap { RouteGeometrySplitter.split($0.coordinates, atDistance: distance).remaining.first ?? $0.coordinates.last }
        }
        do {
            let forecasts = try await provider.forecasts(for: [location] + points)
            try Task.checkCancellation()
            current = forecasts.first?.at(Date(), currentConditions: true)
            var result: [RouteWeatherSample] = []
            if let route, points.count == count {
                let duration = max(0, remainingTime ?? route.expectedTravelTime)
                for index in points.indices {
                    let eta = departure.addingTimeInterval(duration * (distances[index] - start) / max(1, remaining))
                    guard let weather = forecasts[index + 1].at(eta) else { continue }
                    let lower = index == 0 ? start : (distances[index - 1] + distances[index]) / 2
                    let upper = index == count - 1 ? length : (distances[index] + distances[index + 1]) / 2
                    let tail = RouteGeometrySplitter.split(route.coordinates, atDistance: lower).remaining
                    let segment = RouteGeometrySplitter.split(tail, atDistance: upper - lower).completed
                    result.append(RouteWeatherSample(index: index, startDistance: lower, endDistance: upper,
                                                     sampleDistance: distances[index], coordinates: segment, weather: weather))
                }
            }
            samples = result; updatedAt = Date()
            status = current == nil ? "Brak danych o bieżącej pogodzie" : "Prognoza"
            if result.count < count { status += " · niepełna prognoza trasy" }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            current = nil; samples = []; updatedAt = nil
            status = "Pogoda chwilowo niedostępna"
        }
    }

    func upcoming(progress: Double, route: NavigationRoute?, remainingTime: TimeInterval?) -> String? {
        guard let route, route.id == routeID, let updatedAt, Date().timeIntervalSince(updatedAt) < 1800 else { return nil }
        let length = RouteGeometrySplitter.length(of: route.coordinates)
        let position = max(0, min(1, progress)) * length
        guard let sample = samples.first(where: { $0.endDistance > position && $0.weather.condition.isHazard }) else { return nil }
        let distance = max(0, sample.startDistance - position)
        let minutes = max(1, Int(ceil((remainingTime ?? route.expectedTravelTime) * distance / max(1, length - position) / 60)))
        let span = max(1, Int(((sample.endDistance - max(position, sample.startDistance)) / 1000).rounded()))
        if distance < 500 { return "\(sample.weather.condition.title) na tym odcinku · około \(span) km · prognoza" }
        return "\(sample.weather.condition.title) za około \(max(1, Int((distance / 1000).rounded()))) km · ~\(minutes) min · prognoza"
    }
}
