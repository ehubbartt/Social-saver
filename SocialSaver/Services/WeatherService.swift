import Foundation

/// Daily forecast for a coordinate via Open-Meteo (free, no API key).
struct DayWeather {
    let date: String // "yyyy-MM-dd"
    let code: Int
    let tempMax: Double
    let tempMin: Double
    let precipProbability: Int?

    var symbol: String {
        switch code {
        case 0: return "sun.max"
        case 1...3: return "cloud.sun"
        case 45, 48: return "cloud.fog"
        case 51...57, 61...67, 80...82: return "cloud.rain"
        case 71...77, 85, 86: return "cloud.snow"
        case 95...99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }

    var summary: String {
        switch code {
        case 0: return "clear"
        case 1...3: return "partly cloudy"
        case 45, 48: return "foggy"
        case 51...57: return "drizzle"
        case 61...67: return "rain"
        case 71...77, 85, 86: return "snow"
        case 80...82: return "showers"
        case 95...99: return "thunderstorms"
        default: return "cloudy"
        }
    }

    var wearTip: String {
        var tips: [String] = []
        if tempMax >= 27 {
            tips.append("light clothes and water")
        } else if tempMax >= 19 {
            tips.append("comfortable layers")
        } else if tempMax >= 10 {
            tips.append("a light jacket")
        } else {
            tips.append("a warm coat")
        }
        let snowy = (71...77).contains(code) || code == 85 || code == 86
        let rainy = (51...67).contains(code) || (80...82).contains(code) || (95...99).contains(code)
        if snowy {
            tips.append("waterproof shoes")
        } else if rainy || (precipProbability ?? 0) >= 40 {
            tips.append("an umbrella")
        }
        return tips.joined(separator: " and ")
    }
}

struct WeatherService {
    /// Forecast keyed by "yyyy-MM-dd". Open-Meteo covers ~16 days out; the
    /// range is clamped and dates use the place's local timezone.
    func dailyForecast(
        latitude: Double,
        longitude: Double,
        start: Date,
        end: Date
    ) async throws -> [String: DayWeather] {
        let today = Calendar.current.startOfDay(for: .now)
        let maxEnd = Calendar.current.date(byAdding: .day, value: 15, to: today) ?? end
        let clampedStart = max(start, today)
        let clampedEnd = min(end, maxEnd)
        guard clampedStart <= clampedEnd else { return [:] }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "start_date", value: Trip.dayFormatter.string(from: clampedStart)),
            URLQueryItem(name: "end_date", value: Trip.dayFormatter.string(from: clampedEnd)),
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [:] }

        struct Payload: Decodable {
            struct Daily: Decodable {
                let time: [String]
                let weather_code: [Int]
                let temperature_2m_max: [Double]
                let temperature_2m_min: [Double]
                let precipitation_probability_max: [Int?]?
            }
            let daily: Daily
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)

        var result: [String: DayWeather] = [:]
        for (index, date) in payload.daily.time.enumerated() {
            guard index < payload.daily.weather_code.count,
                  index < payload.daily.temperature_2m_max.count,
                  index < payload.daily.temperature_2m_min.count else { continue }
            result[date] = DayWeather(
                date: date,
                code: payload.daily.weather_code[index],
                tempMax: payload.daily.temperature_2m_max[index],
                tempMin: payload.daily.temperature_2m_min[index],
                precipProbability: payload.daily.precipitation_probability_max?[index] ?? nil
            )
        }
        return result
    }
}
