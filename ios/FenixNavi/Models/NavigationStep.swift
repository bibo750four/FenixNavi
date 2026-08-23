import Foundation

/// Represents a single turn-by-turn navigation step.
struct NavigationStep: Codable, Identifiable {
    let id = UUID()
    let instruction: String        // "Turn right onto Hauptstraße"
    let maneuver: String           // "turn_right", "turn_left", etc.
    let streetName: String         // Road name
    var distance: Double           // Distance in meters
    let duration: Double           // Duration in seconds
    let startLocation: Coordinate  // Where this step begins
    let endLocation: Coordinate    // Where this step ends
    let geometry: [Coordinate]     // Full polyline of this step (for map-matching)
    let turnAngle: Double          // Relative turn angle in degrees (-180..180), 0=straight
    let isRoundabout: Bool         // True when this step is a roundabout/rotary maneuver
    let exit: Int?                 // Roundabout exit number (nil for non-roundabouts)
    var isCompleted: Bool = false

    enum CodingKeys: String, CodingKey {
        case instruction, maneuver, streetName, distance, duration
        case startLocation, endLocation, geometry, turnAngle, isRoundabout, exit
    }
}

/// A geographic coordinate.
struct Coordinate: Codable {
    let latitude: Double
    let longitude: Double
}

/// Represents an OSRM route response.
struct RouteResponse: Codable {
    let code: String
    let routes: [Route]?
    let message: String?

    struct Route: Codable {
        let legs: [Leg]
        let distance: Double
        let duration: Double

        struct Leg: Codable {
            let steps: [OSRMStep]
            let distance: Double
            let duration: Double

            struct OSRMStep: Codable {
                let maneuver: Maneuver
                let name: String
                let distance: Double
                let duration: Double
                let geometry: GeoJSONGeometry?
                let intersections: [Intersection]?

                struct GeoJSONGeometry: Codable {
                    let coordinates: [[Double]]
                    let type: String
                }

                struct Maneuver: Codable {
                    let type: String
                    let modifier: String?
                    let instruction: String?
                    let location: [Double]
                    let bearing_before: Double?
                    let bearing_after: Double?
                    let exit: Int?
                }

                struct Intersection: Codable {
                    let location: [Double]
                    let bearings: [Double]
                    let entry: [Bool]?
                    let out: Int?
                    let `in`: Int?
                }
            }
        }
    }

    /// Converts the OSRM response into an array of NavigationStep.
    func toNavigationSteps() -> [NavigationStep] {
        guard let route = routes?.first else { return [] }

        var steps: [NavigationStep] = []

        for leg in route.legs {
            for step in leg.steps {
                let street = step.name.isEmpty ? "Unnamed road" : step.name
                let instructionText = step.maneuver.instruction
                    ?? "\(step.maneuver.type) onto \(street)"

                let startCoord = Coordinate(
                    latitude: step.maneuver.location[1],
                    longitude: step.maneuver.location[0]
                )

                // End coordinate from the geometry's last point, or fall back to start
                let endCoord: Coordinate
                if let coords = step.geometry?.coordinates, let last = coords.last, last.count >= 2 {
                    endCoord = Coordinate(latitude: last[1], longitude: last[0])
                } else {
                    endCoord = startCoord
                }

                // Full polyline geometry for map-matching
                let geometry: [Coordinate] = (step.geometry?.coordinates ?? []).compactMap { coords in
                    guard coords.count >= 2 else { return nil }
                    return Coordinate(latitude: coords[1], longitude: coords[0])
                }

                // Compute the relative turn angle from the maneuver bearings.
                // Positive = right turn, negative = left turn.
                let bearingBefore = step.maneuver.bearing_before ?? 0
                let bearingAfter = step.maneuver.bearing_after ?? 0
                var rawAngle = bearingAfter - bearingBefore
                while rawAngle > 180 { rawAngle -= 360 }
                while rawAngle < -180 { rawAngle += 360 }

                let isRoundabout = step.maneuver.type == "roundabout"
                    || step.maneuver.type == "rotary"
                    || step.maneuver.type == "exit roundabout"
                    || step.maneuver.type == "exit rotary"

                let navStep = NavigationStep(
                    instruction: instructionText,
                    maneuver: normalizeManeuver(type: step.maneuver.type,
                                                 modifier: step.maneuver.modifier),
                    streetName: street,
                    distance: step.distance,
                    duration: step.duration,
                    startLocation: startCoord,
                    endLocation: endCoord,
                    geometry: geometry,
                    turnAngle: rawAngle,
                    isRoundabout: isRoundabout,
                    exit: step.maneuver.exit
                )
                steps.append(navStep)
            }
        }

        return steps
    }

    private func normalizeManeuver(type: String, modifier: String?) -> String {
        switch (type, modifier) {
        case ("depart", _): return "depart"
        case ("arrive", _): return "arrive"
        case ("turn", "left"): return "turn_left"
        case ("turn", "right"): return "turn_right"
        case ("turn", "slight left"): return "slight_left"
        case ("turn", "slight right"): return "slight_right"
        case ("turn", "sharp left"): return "sharp_left"
        case ("turn", "sharp right"): return "sharp_right"
        case ("new name", _), ("continue", _): return "continue"
        case ("rotary", _), ("roundabout", _): return "roundabout"
        case ("exit rotary", _), ("exit roundabout", _): return "roundabout_exit"
        case ("fork", _): return "continue"
        case ("end of road", _): return modifier.map { "turn_\($0)" } ?? "continue"
        case ("use lane", _): return "continue"
        default: return "continue"
        }
    }
}
