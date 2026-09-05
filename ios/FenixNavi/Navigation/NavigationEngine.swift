import Foundation
import CoreLocation
import UIKit

/// Core navigation engine.
///
/// Manages the navigation lifecycle:
/// 1. Calculate route via OSRM
/// 2. Track user's GPS position
/// 3. Determine which step is currently active
/// 4. Send turn instructions to the Garmin watch via GarminBridge
///
/// Published as an @ObservableObject for SwiftUI integration.
@MainActor
class NavigationEngine: NSObject, ObservableObject, CLLocationManagerDelegate {

    // MARK: - Published State

    @Published var isNavigating = false
    @Published var currentStep: NavigationStep?
    @Published var currentStepIndex: Int = 0
    @Published var totalSteps: Int = 0
    @Published var totalDistance: Double = 0
    @Published var totalDuration: Double = 0
    @Published var destinationName: String = ""
    @Published var statusText: String = "Ready"
    @Published var isRerouting = false
    @Published var watchConnected = false
    @Published var isGPSActive = false

    // Geometry-based current maneuver, shared with the watch so the iOS screen
    // shows the same instruction the watch displays (and refreshes on every fix).
    @Published var currentManeuver = ""
    @Published var currentManeuverText = ""
    @Published var currentStreetName = ""
    @Published var distanceToNextTurn: Double = 0
    @Published var currentTurnAngle = 0
    @Published var wrongDirection = false

    // MARK: - Private State

    private let locationManager = CLLocationManager()
    private let routingService = RoutingService()
    private let garminBridge = GarminBridge()
    private var steps: [NavigationStep] = []
    private var currentLocation: CLLocation?
    private var destination: CLLocationCoordinate2D?
    // Destination chosen before the watch was connected / GPS was ready, kept
    // so navigation can start automatically once both are available.
    private var pendingDestination: CLLocationCoordinate2D?
    private var pendingDestinationName: String?
    private var updateTimer: Timer?
    private var lastSentDistanceM: Int = -1
    private var lastSentStepIndex: Int = -1
    private var lastSendTime: Date = .distantPast
    private var lastRerouteTime: Date = .distantPast

    // Geometry-based route segments (built from all steps) for turn detection.
    // This mirrors the simulator's approach: detect the next turn from the
    // polyline geometry (bearing change) rather than OSRM step labels, so turns
    // folded into "continue" steps (e.g. a left turn onto a different branch of
    // the same-named road) are still announced correctly.
    private struct RouteSegment {
        let a: Coordinate
        let b: Coordinate
        let bearing: Double
        let start: Double   // cumulative distance at segment start
        let end: Double     // cumulative distance at segment end
        let stepIndex: Int
    }
    private var routeSegs: [RouteSegment] = []
    private var routeTotalLength: Double = 0

    // Geometry-based maneuver for the current position (built once per check,
    // shared by the iOS display and the watch message).
    private struct ManeuverInfo {
        let maneuver: String
        let maneuverText: String
        let turnAngle: Int
        let streetName: String
        let distanceToTurn: Double
        let wrongDirection: Bool
        let remainingDistance: Double
        let remainingDuration: Double
        let exit: Int
    }

    // MARK: - Setup

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 3  // Update every 3 meters for smooth tracking
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        // Keep delivering fixes during navigation even if the user pauses
        // briefly, so the watch keeps getting updates while the screen is locked.
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - Public API

    /// Start navigating to a destination.
    ///
    /// The destination is remembered even if navigation can't begin immediately
    /// (e.g. the watch isn't connected yet), so it isn't lost. Navigation starts
    /// automatically once the watch connects and a GPS fix is available.
    func startNavigation(to destination: CLLocationCoordinate2D, name: String) async {
        // Remember the destination so it isn't lost if we can't start right away.
        pendingDestination = destination
        pendingDestinationName = name

        // Make sure GPS is running (it may have been turned off after a previous
        // navigation session).
        if !isGPSActive {
            startGPS()
        }

        await beginNavigationIfReady()
    }

    /// Start navigation to the pending destination once the watch is connected
    /// and a usable GPS fix is available. Called when a destination is picked,
    /// when the watch connects, and when a GPS fix arrives.
    private func beginNavigationIfReady() async {
        guard let destination = pendingDestination else { return }
        let name = pendingDestinationName ?? ""

        // Require the watch to be connected first so messages aren't lost
        guard watchConnected else {
            statusText = "Connect your watch first"
            return
        }

        guard let location = currentLocation else {
            statusText = "Waiting for GPS..."
            return
        }
        guard location.horizontalAccuracy <= 20 else {
            statusText = "Waiting for accurate GPS..."
            return
        }

        // We're ready - clear the pending destination so this only runs once.
        pendingDestination = nil
        pendingDestinationName = nil

        destinationName = name
        self.destination = destination
        statusText = "Calculating route..."
        isRerouting = false

        do {
            steps = try await routingService.calculateRoute(
                from: location.coordinate,
                to: destination
            )

            guard !steps.isEmpty else {
                statusText = "No route found"
                return
            }

            buildRouteSegs()

            totalSteps = steps.count
            currentStepIndex = 0
            totalDistance = steps.reduce(0) { $0 + $1.distance }
            totalDuration = steps.reduce(0) { $0 + $1.duration }
            currentStep = steps.first
            isNavigating = true
            statusText = "Navigating"

            // Keep the screen awake while navigating (avoids the screen locking
            // and helps keep the app active).
            UIApplication.shared.isIdleTimerDisabled = true

            // Start periodic position updates for step tracking
            startPositionUpdates()

            // Send first instruction to watch
            refreshManeuverAndSend()

        } catch {
            statusText = "Route error: \(error.localizedDescription)"
        }
    }

    /// Stop navigation.
    func stopNavigation() {
        isNavigating = false
        isRerouting = false
        // Allow the screen to lock again once navigation ends.
        UIApplication.shared.isIdleTimerDisabled = false
        steps = []
        routeSegs = []
        routeTotalLength = 0
        currentStep = nil
        currentStepIndex = 0
        totalSteps = 0
        pendingDestination = nil
        pendingDestinationName = nil
        statusText = "Ready"
        updateTimer?.invalidate()
        updateTimer = nil

        // Release the GPS/location service when navigation is no longer needed.
        stopGPS()

        // Tell watch navigation was stopped (not arrived)
        garminBridge.sendMessage([
            "type": "navigation_stopped"
        ])
    }

    /// Initialize the Garmin bridge. Call once at app start.
    /// Deferred slightly so the ConnectIQ SDK init doesn't block the initial UI render.
    func initializeGarminBridge() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.garminBridge.initialize()
        }
    }

    /// Show device selection in Garmin Connect Mobile.
    func selectWatch() {
        garminBridge.showDeviceSelection()
    }

    // MARK: - Route data for the minimap

    /// Full route polyline (all step geometries concatenated) for the minimap.
    var routeCoordinates: [CLLocationCoordinate2D] {
        steps.flatMap { step in
            step.geometry.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
        }
    }

    /// Current GPS position (for the minimap marker).
    var currentCoordinate: CLLocationCoordinate2D? { currentLocation?.coordinate }

    /// Destination coordinate (for the minimap marker).
    var destinationCoordinate: CLLocationCoordinate2D? { destination }

    /// Start GPS location updates (e.g. when starting navigation).
    func startGPS() {
        locationManager.startUpdatingLocation()
        isGPSActive = true
    }

    /// Stop GPS location updates to release the location service and save battery
    /// when navigation isn't needed.
    func stopGPS() {
        locationManager.stopUpdatingLocation()
        isGPSActive = false
        currentLocation = nil
    }

    /// Handle URL callback from Garmin Connect Mobile.
    func handleGarminURL(_ url: URL) {
        let devices = garminBridge.handleOpenURL(url)
        if !devices.isEmpty {
            watchConnected = true
            // Defer until the watch reports Connected, so the request isn't
            // sent before BLE is ready (which failed with DeviceNotAvailable).
            garminBridge.openAppWhenReady { success in
                print("FenixNavi: App open result: \(success)")
            }
            // If a destination was chosen before the watch was connected, start
            // navigating now that the watch is available.
            Task { await self.beginNavigationIfReady() }
        }
    }

    // MARK: - CLLocationManagerDelegate
    // The delegate methods are nonisolated (called on an arbitrary thread by
    // CLLocationManager), so we dispatch the main-actor work via Task @MainActor.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.handleAuthorizationChange(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.handleLocationUpdate(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }

    // MARK: - Main-actor location helpers

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
            isGPSActive = true
            statusText = "GPS ready"
        case .denied, .restricted:
            statusText = "Location access denied"
        case .notDetermined:
            // Request "Always" so navigation keeps updating in the background
            // (screen locked / app in pocket).
            locationManager.requestAlwaysAuthorization()
        @unknown default:
            break
        }
    }

    private func handleLocationUpdate(_ location: CLLocation) {
        currentLocation = location

        // Filter out low-accuracy fixes (e.g. indoors) to reduce noise
        guard location.horizontalAccuracy <= 20 else {
            return
        }

        currentLocation = location

        // If a destination is pending (e.g. waiting for the watch or a GPS fix),
        // try to start navigation now that we have a usable location.
        if pendingDestination != nil {
            Task { await self.beginNavigationIfReady() }
        }

        guard isNavigating, !steps.isEmpty, !isRerouting else { return }

        checkStepProgress()
    }

    // MARK: - Private

    private func startPositionUpdates() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkStepProgress()
            }
        }
    }

    private func checkStepProgress() {
        guard let location = currentLocation, !routeSegs.isEmpty else {
            return
        }

        let user = location.coordinate
        let proj = projectToFullRoute(user)
        let s = proj.s

        // Off-route detection: if we're far from the route, recalculate.
        // A cooldown prevents repeated reroutes from looping.
        if proj.perp > 30 && Date().timeIntervalSince(lastRerouteTime) > 30 {
            reroute()
            return
        }

        // Determine the current step from cumulative distance along the route.
        let index = stepIndexAt(s)
        if index != currentStepIndex {
            currentStepIndex = index
            currentStep = steps[index]
        }

        // Find the next turn from the route geometry.
        let turn = findNextTurn(at: s)

        // Arrival: no turn ahead and close to the destination.
        if turn == nil && routeTotalLength - s < 30 {
            arrived()
            return
        }

        refreshManeuverAndSend()
    }

    /// Compute the current geometry-based maneuver, expose it to the iOS screen,
    /// and send it to the watch.
    private func refreshManeuverAndSend() {
        guard let location = currentLocation, !routeSegs.isEmpty else { return }
        let s = projectToFullRoute(location.coordinate).s
        let index = stepIndexAt(s)
        let info = computeManeuver(at: s, index: index)
        currentManeuver = info.maneuver
        currentManeuverText = info.maneuverText
        currentStreetName = info.streetName
        distanceToNextTurn = info.distanceToTurn
        currentTurnAngle = info.turnAngle
        wrongDirection = info.wrongDirection
        sendCurrentStepToWatch(info: info)
    }

    /// Build the geometry-based maneuver for the current position along the route.
    /// Shared by the iOS display and the watch message so both stay consistent.
    private func computeManeuver(at s: Double, index: Int) -> ManeuverInfo {
        let turn = findNextTurn(at: s)
        let distanceToTurn = turn?.distance ?? (routeTotalLength - s)
        let wrongDir = isGoingWrongWay(at: s)
        let remainingDistance = routeTotalLength - s
        let remainingDuration = steps[index...].reduce(0) { $0 + $1.duration }

        let maneuver: String
        let maneuverText: String
        let turnAngle: Int
        let streetName: String
        let exit: Int

        if wrongDir {
            maneuver = "uturn"
            maneuverText = "Turn around"
            turnAngle = 180
            streetName = ""
            exit = 0
        } else if let turn {
            let road = roadNameAt(turn.at)
            let turnStepIndex = stepIndexAt(turn.at)
            let isRoundabout = steps[turnStepIndex].isRoundabout
                || (turnStepIndex + 1 < steps.count && steps[turnStepIndex + 1].isRoundabout)

            if isRoundabout {
                // Roundabout: use the net exit direction (approach -> exit road)
                // rather than the raw entry-curve angle, which is misleading.
                exit = steps[turnStepIndex].exit ?? 0
                maneuver = "roundabout"
                maneuverText = "Roundabout, take exit \(exit) onto \(road)"
                turnAngle = roundaboutExitAngle(at: turn.at)
                streetName = road
            } else {
                exit = 0
                let a = abs(turn.angle)
                let dir = turn.angle > 0 ? "right" : "left"
                let strength: String
                if a <= 60 { strength = "Bear " }
                else if a <= 120 { strength = "Turn " }
                else { strength = "Sharp " }
                maneuver = "turn_\(dir)"
                maneuverText = "\(strength)\(dir) onto \(road)"
                turnAngle = Int(turn.angle)
                streetName = road
            }
        } else {
            maneuver = "arrive"
            maneuverText = "Arrive at destination"
            turnAngle = 0
            streetName = ""
            exit = 0
        }

        return ManeuverInfo(
            maneuver: maneuver,
            maneuverText: maneuverText,
            turnAngle: turnAngle,
            streetName: streetName,
            distanceToTurn: distanceToTurn,
            wrongDirection: wrongDir,
            remainingDistance: remainingDistance,
            remainingDuration: remainingDuration,
            exit: exit
        )
    }

    private func sendCurrentStepToWatch(info: ManeuverInfo) {
        guard currentLocation != nil, !routeSegs.isEmpty else { return }
        let distM = Int(info.distanceToTurn)

        // Throttle: only send when the step or distance changes meaningfully.
        // But always send at least every 15s (a heartbeat) so the watch doesn't
        // time out and return to the waiting screen while the user is stationary.
        let changed = currentStepIndex != lastSentStepIndex || distM != lastSentDistanceM
        let heartbeatDue = Date().timeIntervalSince(lastSendTime) >= 15
        if !changed && !heartbeatDue {
            return
        }
        lastSentStepIndex = currentStepIndex
        lastSentDistanceM = distM
        lastSendTime = Date()

        let message: [String: Any] = [
            "type": "navigation_update",
            "step_index": currentStepIndex,
            "total_steps": totalSteps,
            "maneuver": info.maneuver,
            "maneuver_text": info.maneuverText,
            "street_name": info.streetName,
            "distance_m": distM,
            "duration_s": Int(info.remainingDuration),
            "turn_angle": info.turnAngle,
            "wrong_direction": info.wrongDirection,
            "exit": info.exit,
            "total_distance_km": info.remainingDistance / 1000.0,
            "total_duration_min": Int(info.remainingDuration / 60.0),
            "eta_min": Int(info.remainingDuration / 60.0)
        ]

        garminBridge.sendMessage(message)
    }

    // MARK: - Map Matching


    /// Haversine distance between two coordinates in meters.
    private func haversineDistance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let R = 6371000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
              + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * R * asin(sqrt(h))
    }

    /// Project a point onto a line segment (in local meters). Returns the
    /// projected coordinate and the perpendicular distance to the segment.
    private func projectToSegment(_ p: CLLocationCoordinate2D,
                                  _ a: Coordinate, _ b: Coordinate) -> (Coordinate, Double) {
        let latRef = (a.latitude + b.latitude) / 2 * .pi / 180
        let metersPerLat = 111320.0
        let metersPerLon = 111320.0 * cos(latRef)

        let ax = a.longitude * metersPerLon
        let ay = a.latitude * metersPerLat
        let bx = b.longitude * metersPerLon
        let by = b.latitude * metersPerLat
        let px = p.longitude * metersPerLon
        let py = p.latitude * metersPerLat

        let dx = bx - ax
        let dy = by - ay
        let len2 = dx * dx + dy * dy
        var t = ((px - ax) * dx + (py - ay) * dy) / len2
        t = max(0, min(1, t))

        let projX = ax + t * dx
        let projY = ay + t * dy
        let proj = Coordinate(latitude: projY / metersPerLat,
                              longitude: projX / metersPerLon)
        let dist = sqrt((px - projX) * (px - projX) + (py - projY) * (py - projY))
        return (proj, dist)
    }

    /// Build the flat list of route segments with cumulative distances and
    /// bearings, used for geometry-based turn detection.
    private func buildRouteSegs() {
        routeSegs = []
        var acc: Double = 0
        for (si, step) in steps.enumerated() {
            for i in 0..<(step.geometry.count - 1) {
                let a = step.geometry[i]
                let b = step.geometry[i + 1]
                let len = haversineDistance(a, b)
                routeSegs.append(RouteSegment(a: a, b: b,
                                              bearing: bearingBetween(a, b),
                                              start: acc, end: acc + len,
                                              stepIndex: si))
                acc += len
            }
        }
        routeTotalLength = acc
    }

    /// Project a coordinate onto the full route polyline. Returns the cumulative
    /// distance s along the route, the perpendicular distance, and the local bearing.
    private func projectToFullRoute(_ user: CLLocationCoordinate2D)
        -> (s: Double, perp: Double, bearing: Double?) {
        var best = (s: 0.0, perp: Double.greatestFiniteMagnitude, bearing: Double?.none)
        for seg in routeSegs {
            let (proj, dist) = projectToSegment(user, seg.a, seg.b)
            if dist < best.perp {
                best.perp = dist
                best.s = seg.start + haversineDistance(seg.a, proj)
                best.bearing = seg.bearing
            }
        }
        return best
    }

    /// Find the next significant turn ahead of cumulative distance s, from the
    /// route geometry (bearing change) rather than OSRM step labels.
    private func findNextTurn(at s: Double) -> (distance: Double, angle: Double, at: Double)? {
        guard !routeSegs.isEmpty else { return nil }
        var idx = 0
        while idx < routeSegs.count - 1 && routeSegs[idx].end < s { idx += 1 }
        let ref = routeSegs[idx].bearing
        for i in idx..<routeSegs.count {
            let rel = normalizeAngle(routeSegs[i].bearing - ref)
            if abs(rel) > 30 {
                return (max(0, routeSegs[i].start - s), rel, routeSegs[i].start)
            }
        }
        return nil
    }

    /// Which step contains cumulative distance s.
    private func stepIndexAt(_ s: Double) -> Int {
        for seg in routeSegs {
            if s <= seg.end { return seg.stepIndex }
        }
        return steps.count - 1
    }

    /// Road name at/after cumulative distance s (the road you turn onto).
    private func roadNameAt(_ s: Double) -> String {
        for seg in routeSegs {
            if s < seg.end { return steps[seg.stepIndex].streetName }
        }
        return steps[steps.count - 1].streetName
    }

    /// Net exit direction (degrees, 0=straight, +right, -left) for a roundabout,
    /// computed from the approach road bearing to the exit road bearing.
    private func roundaboutExitAngle(at turnS: Double) -> Int {
        let stepIndex = stepIndexAt(turnS)

        // Approach bearing: from the segment just before the roundabout step
        var approach: Double?
        if stepIndex > 0 {
            let prev = steps[stepIndex - 1]
            if prev.geometry.count >= 2 {
                approach = bearingBetween(prev.geometry[prev.geometry.count - 2],
                                          prev.geometry[prev.geometry.count - 1])
            }
        }
        if approach == nil, steps[stepIndex].geometry.count >= 2 {
            approach = bearingBetween(steps[stepIndex].geometry[0],
                                      steps[stepIndex].geometry[1])
        }

        // Exit bearing: from the segment just after the roundabout step
        var exitBearing: Double?
        if stepIndex + 1 < steps.count {
            let next = steps[stepIndex + 1]
            if next.geometry.count >= 2 {
                exitBearing = bearingBetween(next.geometry[0], next.geometry[1])
            }
        }
        if exitBearing == nil, steps[stepIndex].geometry.count >= 2 {
            let g = steps[stepIndex].geometry
            exitBearing = bearingBetween(g[g.count - 2], g[g.count - 1])
        }

        guard let a = approach, let b = exitBearing else { return 0 }
        return Int(normalizeAngle(b - a))
    }

    /// Recalculate the route from the current position to the destination.
    private func reroute() {
        guard let location = currentLocation, let dest = destination else { return }
        lastRerouteTime = Date()
        isRerouting = true
        statusText = "Rerouting..."
        Task {
            do {
                let newSteps = try await routingService.calculateRoute(
                    from: location.coordinate, to: dest)
                if !newSteps.isEmpty {
                    steps = newSteps
                    buildRouteSegs()
                    totalSteps = newSteps.count
                    currentStepIndex = 0
                    totalDistance = newSteps.reduce(0) { $0 + $1.distance }
                    totalDuration = newSteps.reduce(0) { $0 + $1.duration }
                    currentStep = steps.first
                    isRerouting = false
                    statusText = "Navigating"
                    refreshManeuverAndSend()
                } else {
                    isRerouting = false
                    statusText = "No reroute found"
                }
            } catch {
                isRerouting = false
                statusText = "Reroute error"
            }
        }
    }

    /// Detect if the user is heading the wrong way along the route.
    private func isGoingWrongWay(at s: Double) -> Bool {
        guard let loc = currentLocation, loc.course >= 0,
              let routeBearing = routeBearingAt(s) else {
            return false
        }
        let diff = abs(normalizeAngle(routeBearing - loc.course))
        return diff > 90
    }

    /// Bearing of the route segment at cumulative distance s.
    private func routeBearingAt(_ s: Double) -> Double? {
        guard !routeSegs.isEmpty else { return nil }
        var idx = 0
        while idx < routeSegs.count - 1 && routeSegs[idx].end < s { idx += 1 }
        return routeSegs[idx].bearing
    }

    private func bearingBetween(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var deg = atan2(y, x) * 180 / .pi
        deg = deg.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        return deg
    }

    private func normalizeAngle(_ a: Double) -> Double {
        var a = a
        while a > 180 { a -= 360 }
        while a < -180 { a += 360 }
        return a
    }

    private func arrived() {
        isNavigating = false
        currentStep = nil
        statusText = "Arrived at \(destinationName)"
        updateTimer?.invalidate()
        updateTimer = nil

        // Notify watch
        garminBridge.sendMessage([
            "type": "navigation_end"
        ])
    }
}
