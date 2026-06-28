import Foundation

#if canImport(CoreLocation)
import CoreLocation
#endif

#if canImport(WeatherKit)
import WeatherKit
#endif

struct WeatherReport: Sendable, Equatable {
    var locationName: String
    var condition: String
    var temperature: Double
    var temperatureUnit: String
    var humidityPercent: Int
    var windSpeed: Double
    var windUnit: String
    var provider: String
    var target: String
    var statusCode: Int?
    var latencyMs: Double
    var forecastSummary: String?
}

protocol WeatherService: Sendable {
    func currentWeather(for location: String) async throws -> WeatherReport
    func forecastWeather(for location: String, dayOffset: Int) async throws -> WeatherReport
    #if canImport(CoreLocation)
    func currentWeather(at location: CLLocation, locationName: String) async throws -> WeatherReport
    func forecastWeather(at location: CLLocation, locationName: String, dayOffset: Int) async throws -> WeatherReport
    #endif
}

enum WeatherServiceError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidEndpoint
    case weatherKitUnavailable(String)
    case geocodingFailed(String)
    case forecastUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Weather API key is missing. Add an OpenWeather-compatible key in Settings, or enable WeatherKit for this app target."
        case .invalidEndpoint:
            "Weather endpoint in Settings is not a valid URL."
        case .weatherKitUnavailable(let reason):
            "WeatherKit is unavailable: \(reason)"
        case .geocodingFailed(let location):
            "Could not geocode weather location: \(location)."
        case .forecastUnavailable(let reason):
            "Weather forecast is unavailable: \(reason)"
        }
    }
}

enum WeatherServiceFactory {
    static func makeConfiguredService() -> any WeatherService {
        CompositeWeatherService(
            primary: WeatherKitWeatherService(),
            fallback: OpenWeatherCompatibleWeatherService(
                endpoint: AppNetworkConfiguration.weatherEndpoint,
                apiKey: AppNetworkConfiguration.weatherAPIKey,
                units: AppNetworkConfiguration.weatherUnits,
                client: AppNetworkConfiguration.client()
            )
        )
    }
}

struct CompositeWeatherService: WeatherService {
    var primary: (any WeatherService)?
    var fallback: any WeatherService

    func currentWeather(for location: String) async throws -> WeatherReport {
        if let primary {
            do {
                return try await primary.currentWeather(for: location)
            } catch WeatherServiceError.weatherKitUnavailable {
                return try await fallback.currentWeather(for: location)
            } catch {
                if AppNetworkConfiguration.weatherAPIKey.isEmpty {
                    throw error
                }
                return try await fallback.currentWeather(for: location)
            }
        }
        return try await fallback.currentWeather(for: location)
    }

    func forecastWeather(for location: String, dayOffset: Int) async throws -> WeatherReport {
        if let primary {
            do {
                return try await primary.forecastWeather(for: location, dayOffset: dayOffset)
            } catch WeatherServiceError.weatherKitUnavailable {
                return try await fallback.forecastWeather(for: location, dayOffset: dayOffset)
            } catch WeatherServiceError.forecastUnavailable {
                return try await fallback.forecastWeather(for: location, dayOffset: dayOffset)
            } catch {
                if AppNetworkConfiguration.weatherAPIKey.isEmpty {
                    throw error
                }
                return try await fallback.forecastWeather(for: location, dayOffset: dayOffset)
            }
        }
        return try await fallback.forecastWeather(for: location, dayOffset: dayOffset)
    }

    #if canImport(CoreLocation)
    func currentWeather(at location: CLLocation, locationName: String) async throws -> WeatherReport {
        if let primary {
            do {
                return try await primary.currentWeather(at: location, locationName: locationName)
            } catch WeatherServiceError.weatherKitUnavailable {
                return try await fallback.currentWeather(at: location, locationName: locationName)
            } catch {
                if AppNetworkConfiguration.weatherAPIKey.isEmpty {
                    throw error
                }
                return try await fallback.currentWeather(at: location, locationName: locationName)
            }
        }
        return try await fallback.currentWeather(at: location, locationName: locationName)
    }

    func forecastWeather(at location: CLLocation, locationName: String, dayOffset: Int) async throws -> WeatherReport {
        if let primary {
            do {
                return try await primary.forecastWeather(at: location, locationName: locationName, dayOffset: dayOffset)
            } catch WeatherServiceError.weatherKitUnavailable {
                return try await fallback.forecastWeather(at: location, locationName: locationName, dayOffset: dayOffset)
            } catch WeatherServiceError.forecastUnavailable {
                return try await fallback.forecastWeather(at: location, locationName: locationName, dayOffset: dayOffset)
            } catch {
                if AppNetworkConfiguration.weatherAPIKey.isEmpty {
                    throw error
                }
                return try await fallback.forecastWeather(at: location, locationName: locationName, dayOffset: dayOffset)
            }
        }
        return try await fallback.forecastWeather(at: location, locationName: locationName, dayOffset: dayOffset)
    }
    #endif
}

struct WeatherKitWeatherService: WeatherService {
    func currentWeather(for location: String) async throws -> WeatherReport {
        #if canImport(WeatherKit) && canImport(CoreLocation)
        let placemarks: [CLPlacemark]
        do {
            placemarks = try await CLGeocoder().geocodeAddressString(location)
        } catch {
            throw WeatherServiceError.geocodingFailed(location)
        }
        guard let coordinate = placemarks.first?.location?.coordinate else {
            throw WeatherServiceError.geocodingFailed(location)
        }
        return try await currentWeather(at: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), locationName: placemarks.first?.locality ?? placemarks.first?.name ?? location)
        #else
        throw WeatherServiceError.weatherKitUnavailable("WeatherKit is not available in this build.")
        #endif
    }

    func forecastWeather(for location: String, dayOffset: Int) async throws -> WeatherReport {
        #if canImport(WeatherKit) && canImport(CoreLocation)
        let placemarks: [CLPlacemark]
        do {
            placemarks = try await CLGeocoder().geocodeAddressString(location)
        } catch {
            throw WeatherServiceError.geocodingFailed(location)
        }
        guard let coordinate = placemarks.first?.location?.coordinate else {
            throw WeatherServiceError.geocodingFailed(location)
        }
        return try await forecastWeather(at: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), locationName: placemarks.first?.locality ?? placemarks.first?.name ?? location, dayOffset: dayOffset)
        #else
        throw WeatherServiceError.weatherKitUnavailable("WeatherKit is not available in this build.")
        #endif
    }

    #if canImport(CoreLocation)
    func currentWeather(at location: CLLocation, locationName: String) async throws -> WeatherReport {
        #if canImport(WeatherKit)
        let started = ContinuousClock.now
        do {
            let weather = try await WeatherKit.WeatherService.shared.weather(for: location)
            let current = weather.currentWeather
            let temperature = current.temperature.converted(to: UnitTemperature.celsius).value
            let windSpeed = current.wind.speed.converted(to: UnitSpeed.metersPerSecond).value
            let latency = Self.latencyMilliseconds(started.duration(to: ContinuousClock.now))
            return WeatherReport(
                locationName: locationName,
                condition: current.condition.description,
                temperature: temperature,
                temperatureUnit: "C",
                humidityPercent: Int((current.humidity * 100).rounded()),
                windSpeed: windSpeed,
                windUnit: "m/s",
                provider: "WeatherKit",
                target: "weatherkit.apple.com",
                statusCode: nil,
                latencyMs: latency,
                forecastSummary: nil
            )
        } catch {
            throw WeatherServiceError.weatherKitUnavailable(error.localizedDescription)
        }
        #else
        throw WeatherServiceError.weatherKitUnavailable("WeatherKit is not available in this build.")
        #endif
    }

    func forecastWeather(at location: CLLocation, locationName: String, dayOffset: Int) async throws -> WeatherReport {
        #if canImport(WeatherKit)
        let started = ContinuousClock.now
        do {
            let weather = try await WeatherKit.WeatherService.shared.weather(for: location)
            let current = weather.currentWeather
            let targetDate = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
            let day = weather.dailyForecast.forecast.first { Calendar.current.isDate($0.date, inSameDayAs: targetDate) }
                ?? weather.dailyForecast.forecast.dropFirst(max(0, dayOffset)).first
            guard let day else {
                throw WeatherServiceError.forecastUnavailable("WeatherKit returned no daily forecast for that date.")
            }

            let temperature = current.temperature.converted(to: UnitTemperature.celsius).value
            let windSpeed = current.wind.speed.converted(to: UnitSpeed.metersPerSecond).value
            let high = day.highTemperature.converted(to: UnitTemperature.celsius).value
            let low = day.lowTemperature.converted(to: UnitTemperature.celsius).value
            let precipitation = Int((day.precipitationChance * 100).rounded())
            let label = dayOffset == 1 ? "Tomorrow" : DateFormatter.localizedString(from: day.date, dateStyle: .medium, timeStyle: .none)
            let latency = Self.latencyMilliseconds(started.duration(to: ContinuousClock.now))
            return WeatherReport(
                locationName: locationName,
                condition: current.condition.description,
                temperature: temperature,
                temperatureUnit: "C",
                humidityPercent: Int((current.humidity * 100).rounded()),
                windSpeed: windSpeed,
                windUnit: "m/s",
                provider: "WeatherKit",
                target: "weatherkit.apple.com",
                statusCode: nil,
                latencyMs: latency,
                forecastSummary: "\(label): \(day.condition.description), high \(Int(high.rounded()))°C, low \(Int(low.rounded()))°C, precipitation \(precipitation)%"
            )
        } catch let error as WeatherServiceError {
            throw error
        } catch {
            throw WeatherServiceError.weatherKitUnavailable(error.localizedDescription)
        }
        #else
        throw WeatherServiceError.weatherKitUnavailable("WeatherKit is not available in this build.")
        #endif
    }
    #endif

    private static func latencyMilliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds * 1_000) + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}

struct OpenWeatherCompatibleWeatherService: WeatherService {
    var endpoint: String
    var apiKey: String
    var units: String
    var client: NetworkClient

    func currentWeather(for location: String) async throws -> WeatherReport {
        guard !apiKey.isEmpty else {
            throw WeatherServiceError.missingAPIKey
        }
        guard var components = URLComponents(string: endpoint) else {
            throw WeatherServiceError.invalidEndpoint
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "q", value: location))
        queryItems.append(URLQueryItem(name: "appid", value: apiKey))
        queryItems.append(URLQueryItem(name: "units", value: units))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw WeatherServiceError.invalidEndpoint
        }

        let response = try await client.send(NetworkRequest(url: url, acceptedContentTypes: ["application/json"]))
        let weather = try response.decodedJSON(OpenWeatherPayload.self)
        let unit = Self.temperatureUnit(for: units)
        return WeatherReport(
            locationName: weather.name.isEmpty ? location : weather.name,
            condition: weather.weather.first?.description ?? "conditions unavailable",
            temperature: weather.main.temp,
            temperatureUnit: unit,
            humidityPercent: weather.main.humidity,
            windSpeed: weather.wind?.speed ?? 0,
            windUnit: units == "imperial" ? "mph" : "m/s",
            provider: "OpenWeather-compatible",
            target: response.finalURL.host ?? response.finalURL.absoluteString,
            statusCode: response.statusCode,
            latencyMs: response.latencyMs,
            forecastSummary: nil
        )
    }

    func forecastWeather(for location: String, dayOffset: Int) async throws -> WeatherReport {
        throw WeatherServiceError.forecastUnavailable("The configured OpenWeather-compatible current-weather endpoint does not provide daily forecast data.")
    }

    #if canImport(CoreLocation)
    func currentWeather(at location: CLLocation, locationName: String) async throws -> WeatherReport {
        guard !apiKey.isEmpty else {
            throw WeatherServiceError.missingAPIKey
        }
        guard var components = URLComponents(string: endpoint) else {
            throw WeatherServiceError.invalidEndpoint
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "lat", value: String(location.coordinate.latitude)))
        queryItems.append(URLQueryItem(name: "lon", value: String(location.coordinate.longitude)))
        queryItems.append(URLQueryItem(name: "appid", value: apiKey))
        queryItems.append(URLQueryItem(name: "units", value: units))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw WeatherServiceError.invalidEndpoint
        }

        let response = try await client.send(NetworkRequest(url: url, acceptedContentTypes: ["application/json"]))
        let weather = try response.decodedJSON(OpenWeatherPayload.self)
        let unit = Self.temperatureUnit(for: units)
        return WeatherReport(
            locationName: weather.name.isEmpty ? locationName : weather.name,
            condition: weather.weather.first?.description ?? "conditions unavailable",
            temperature: weather.main.temp,
            temperatureUnit: unit,
            humidityPercent: weather.main.humidity,
            windSpeed: weather.wind?.speed ?? 0,
            windUnit: units == "imperial" ? "mph" : "m/s",
            provider: "OpenWeather-compatible",
            target: response.finalURL.host ?? response.finalURL.absoluteString,
            statusCode: response.statusCode,
            latencyMs: response.latencyMs,
            forecastSummary: nil
        )
    }

    func forecastWeather(at location: CLLocation, locationName: String, dayOffset: Int) async throws -> WeatherReport {
        throw WeatherServiceError.forecastUnavailable("The configured OpenWeather-compatible current-weather endpoint does not provide daily forecast data.")
    }
    #endif

    private static func temperatureUnit(for units: String) -> String {
        switch units {
        case "imperial":
            return "F"
        case "standard":
            return "K"
        default:
            return "C"
        }
    }
}

private struct OpenWeatherPayload: Decodable {
    var name: String
    var weather: [Condition]
    var main: Main
    var wind: Wind?

    struct Condition: Decodable {
        var description: String
    }

    struct Main: Decodable {
        var temp: Double
        var humidity: Int
    }

    struct Wind: Decodable {
        var speed: Double
    }
}
