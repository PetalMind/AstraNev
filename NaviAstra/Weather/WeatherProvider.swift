import Foundation

nonisolated struct WeatherForecast: Decodable, Sendable {
    struct Current: Decodable, Sendable {
        let time: Double
        let weather_code: Int?
        let precipitation: Double?
        let wind_speed_10m: Double?
        let wind_direction_10m: Double?
        let is_day: Int?
    }
    struct Hourly: Decodable, Sendable {
        let time: [Double]
        let weather_code: [Int?]
        let precipitation: [Double?]
        let visibility: [Double?]
        let wind_speed_10m: [Double?]
        let wind_direction_10m: [Double?]
        let is_day: [Int?]
    }
    let current: Current
    let hourly: Hourly

    func at(_ date: Date, currentConditions: Bool = false) -> WeatherVisualState? {
        guard let index = hourly.time.indices.min(by: {
            abs(hourly.time[$0] - date.timeIntervalSince1970) < abs(hourly.time[$1] - date.timeIntervalSince1970)
        }), abs(hourly.time[index] - date.timeIntervalSince1970) <= 3600,
              hourly.weather_code.indices.contains(index), hourly.precipitation.indices.contains(index),
              hourly.visibility.indices.contains(index), hourly.wind_speed_10m.indices.contains(index),
              hourly.wind_direction_10m.indices.contains(index), hourly.is_day.indices.contains(index),
              let code = currentConditions ? current.weather_code : hourly.weather_code[index],
              let precipitation = currentConditions ? current.precipitation : hourly.precipitation[index],
              let wind = currentConditions ? current.wind_speed_10m : hourly.wind_speed_10m[index],
              let direction = currentConditions ? current.wind_direction_10m : hourly.wind_direction_10m[index],
              let daylight = currentConditions ? current.is_day : hourly.is_day[index] else { return nil }
        return WeatherVisualState(condition: WeatherCondition(code: code), visibility: hourly.visibility[index],
                                  precipitation: precipitation, windSpeed: wind, windDirection: direction,
                                  isDaylight: daylight == 1,
                                  date: currentConditions ? Date(timeIntervalSince1970: current.time) : date)
    }
}

nonisolated protocol WeatherProviding: Sendable {
    func forecasts(for coordinates: [Coordinate]) async throws -> [WeatherForecast]
}

nonisolated struct OpenMeteoWeatherProvider: WeatherProviding {
    func forecasts(for coordinates: [Coordinate]) async throws -> [WeatherForecast] {
        guard !coordinates.isEmpty else { return [] }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: coordinates.map { String($0.latitude) }.joined(separator: ",")),
            .init(name: "longitude", value: coordinates.map { String($0.longitude) }.joined(separator: ",")),
            .init(name: "current", value: "weather_code,precipitation,wind_speed_10m,wind_direction_10m,is_day"),
            .init(name: "hourly", value: "weather_code,precipitation,visibility,wind_speed_10m,wind_direction_10m,is_day"),
            .init(name: "timeformat", value: "unixtime"), .init(name: "wind_speed_unit", value: "ms"),
            .init(name: "forecast_days", value: "3")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        let results = coordinates.count == 1 ? [try decoder.decode(WeatherForecast.self, from: data)]
            : try decoder.decode([WeatherForecast].self, from: data)
        guard results.count == coordinates.count else { throw URLError(.cannotParseResponse) }
        return results
    }
}
