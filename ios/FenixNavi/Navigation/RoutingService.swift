import Foundation
import CoreLocation

/// Service that communicates with the OSRM routing API.
///
/// Uses the free FOSSGIS-hosted OSRM server:
///   https://routing.openstreetmap.de/routed-bike/route/v1/bike/{coords}?steps=true&geometries=geojson&overview=full
///
/// Usage policy: max 1 request per second, non-commercial use,
/// display attribution to OpenStreetMap.
class RoutingService {
    // Alternative base URLs (uncomment to switch):
    // - router.project-osrm.org (car only on demo, bike may not work)
    // - routing.openstreetmap.de/routed-bike (bike profile, worldwide)

    static let baseURL = "https://routing.openstreetmap.de/routed-bike"

    private var lastRequestTime: Date = .distantPast
    private let minInterval: TimeInterval = 1.0  // Rate limit: 1 req/s

    /// Calculate a cycling route between two coordinates.
    /// - Parameters:
    ///   - from: Starting coordinate
    ///   - to: Destination coordinate
    /// - Returns: Array of navigation steps, or nil on failure
    func calculateRoute(from: CLLocationCoordinate2D,
                       to: CLLocationCoordinate2D) async throws -> [NavigationStep] {

        // Rate limiting
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < minInterval {
            try await Task.sleep(nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
        }

        // OSRM expects lon,lat format
        let coordString = "\(from.longitude),\(from.latitude);\(to.longitude),\(to.latitude)"

        guard var components = URLComponents(string: "\(Self.baseURL)/route/v1/bike/\(coordString)") else {
            throw RoutingError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "steps", value: "true"),
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "alternatives", value: "false"),
            URLQueryItem(name: "generate_hints", value: "false"),
        ]

        guard let url = components.url else {
            throw RoutingError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("FenixNavi/1.0 (iOS; Garmin companion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        lastRequestTime = Date()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RoutingError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw RoutingError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let routeResponse = try decoder.decode(RouteResponse.self, from: data)

        guard routeResponse.code == "Ok" else {
            throw RoutingError.routingFailed(routeResponse.message ?? "Unknown error")
        }

        return routeResponse.toNavigationSteps()
    }

    /// Geocode an address string using Nominatim (free OSM geocoder).
    /// - Parameter query: Address or place name to search
    /// - Returns: Array of matching locations with coordinates and names
    func geocode(query: String) async throws -> [GeocodingResult] {
        guard var components = URLComponents(string: "https://nominatim.openstreetmap.org/search") else {
            throw RoutingError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "accept-language", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]

        guard let url = components.url else {
            throw RoutingError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("FenixNavi/1.0 (iOS; Garmin companion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RoutingError.networkError("Geocoding failed")
        }

        let results = try JSONDecoder().decode([NominatimResult].self, from: data)
        return results.map { result in
            GeocodingResult(
                name: result.display_name,
                coordinate: CLLocationCoordinate2D(
                    latitude: Double(result.lat) ?? 0,
                    longitude: Double(result.lon) ?? 0
                )
            )
        }
    }
}

// MARK: - Types

struct GeocodingResult: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
}

enum RoutingError: LocalizedError {
    case invalidURL
    case networkError(String)
    case httpError(Int)
    case routingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .networkError(let msg): return "Network error: \(msg)"
        case .httpError(let code): return "HTTP error \(code)"
        case .routingFailed(let msg): return "Routing failed: \(msg)"
        }
    }
}

// MARK: - Nominatim JSON Models

private struct NominatimResult: Codable {
    let place_id: Int
    let display_name: String
    let lat: String
    let lon: String
}
