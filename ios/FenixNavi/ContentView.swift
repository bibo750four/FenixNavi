import SwiftUI
import CoreLocation
import MapKit

/// Main view for the FenixNavi iOS companion app.
///
/// Allows the user to:
/// - Search for a destination using free-form text (Nominatim geocoding)
/// - Start cycling navigation
/// - See current navigation status
/// - Connect/disconnect from the Garmin watch
struct ContentView: View {
    @EnvironmentObject var navEngine: NavigationEngine
    @State private var searchQuery = ""
    @State private var searchResults: [GeocodingResult] = []
    @State private var isSearching = false
    @State private var selectedDestination: GeocodingResult?
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showRouteMap = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if navEngine.isNavigating {
                    navigationView
                } else {
                    searchView
                }
            }
            .navigationTitle("FenixNavi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        // GPS on/off toggle
                        Button {
                            if navEngine.isGPSActive {
                                navEngine.stopGPS()
                            } else {
                                navEngine.startGPS()
                            }
                        } label: {
                            Image(systemName: navEngine.isGPSActive ? "location.fill" : "location.slash")
                                .foregroundColor(navEngine.isGPSActive ? .green : .gray)
                        }
                        .help(navEngine.isGPSActive ? "Turn GPS off" : "Turn GPS on")

                        // Watch connection status
                        Button {
                            navEngine.selectWatch()
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(navEngine.watchConnected ? Color.green : Color.red)
                                    .frame(width: 10, height: 10)
                                Text(navEngine.watchConnected ? "Watch OK" : "No Watch")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .alert("FenixNavi", isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
        .onAppear {
            navEngine.initializeGarminBridge()
        }
    }

    // MARK: - Search & Destination Selection

    var searchView: some View {
        VStack(spacing: 12) {
            // Header (kept compact so the results list gets more vertical space)
            VStack(spacing: 2) {
                Image(systemName: "bicycle")
                    .font(.system(size: 32))
                    .foregroundColor(.green)
                Text("Cycle Navigation")
                    .font(.headline)
                Text("to Garmin Watch")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)

            // Search field
            HStack {
                TextField("Search destination...", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        performSearch()
                    }

                Button {
                    performSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .padding(8)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }
                .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)

            // Route confirmation minimap (below the search bar)
            if !navEngine.routeCoordinates.isEmpty {
                Button {
                    showRouteMap.toggle()
                } label: {
                    Label(showRouteMap ? "Hide route map" : "Show route map",
                          systemImage: showRouteMap ? "map.fill" : "map")
                        .font(.caption)
                }
                .padding(.horizontal)

                if showRouteMap {
                    RouteMapView(route: navEngine.routeCoordinates,
                                 current: navEngine.currentCoordinate,
                                 destination: navEngine.destinationCoordinate)
                        .padding(.horizontal)
                        .padding(.top, 4)
                }
            }

            if isSearching {
                ProgressView("Searching...")
                    .padding()
            }

            // Search results - expand to fill the remaining space and let the
            // user scroll to dismiss the keyboard (frees more room for results).
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(searchResults) { result in
                        Button {
                            selectDestination(result)
                        } label: {
                            HStack {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.title3)
                                Text(result.name)
                                    .font(.body)
                                    .lineLimit(2)
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal)
                        }
                        Divider()
                            .padding(.leading)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)

            // Status
            if !navEngine.statusText.isEmpty && !navEngine.isNavigating {
                Text(navEngine.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Attribution (required by OSRM / Nominatim usage policy)
            Text("Routing: OpenStreetMap contributors\nvia OSRM & Nominatim")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 10)
        }
    }

    // MARK: - Navigation View

    var navigationView: some View {
        VStack(spacing: 0) {
            // Current instruction (geometry-based, matches the watch)
            VStack(spacing: 16) {
                // Maneuver icon
                Image(systemName: maneuverIcon(navEngine.currentManeuver))
                    .font(.system(size: 56))
                    .foregroundColor(.green)

                // Instruction text
                Text(navEngine.currentManeuverText)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // Distance to turn
                Text(formatDistance(navEngine.distanceToNextTurn))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(.green)
            }
            .padding(.top, 30)

            // Street name
            if !navEngine.currentStreetName.isEmpty {
                Text(navEngine.currentStreetName)
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }

            // Trip info
            HStack(spacing: 30) {
                VStack {
                    Text("ETA")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(navEngine.totalDuration > 0 ? Int(navEngine.totalDuration / 60) : 0) min")
                        .font(.title3.bold())
                }

                VStack {
                    Text("Remaining")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatDistance(navEngine.totalDistance))
                        .font(.title3.bold())
                }

                VStack {
                    Text("Step")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(navEngine.currentStepIndex + 1)/\(navEngine.totalSteps)")
                        .font(.title3.bold())
                }
            }
            .padding(.top, 20)

            // Re-routing indicator
            if navEngine.isRerouting {
                ProgressView("Rerouting...")
                    .padding()
            }

            // Route confirmation minimap (below the navigation info)
            Button {
                showRouteMap.toggle()
            } label: {
                Label(showRouteMap ? "Hide route map" : "Show route map",
                      systemImage: showRouteMap ? "map.fill" : "map")
                    .font(.caption)
            }
            .padding(.top, 8)

            if showRouteMap {
                RouteMapView(route: navEngine.routeCoordinates,
                             current: navEngine.currentCoordinate,
                             destination: navEngine.destinationCoordinate)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }

            // Destination
            Text("To: \(navEngine.destinationName)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 10)
                .lineLimit(1)

            Spacer()

            // Stop button
            Button(role: .destructive) {
                navEngine.stopNavigation()
            } label: {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                    Text("Stop Navigation")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .transition(.opacity)
        .animation(.easeInOut, value: navEngine.isNavigating)
    }

    // MARK: - Actions

    private func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        isSearching = true
        searchResults = []

        Task {
            do {
                let results = try await RoutingService().geocode(query: query)
                await MainActor.run {
                    searchResults = results
                    isSearching = false
                    if results.isEmpty {
                        alertMessage = "No results found for \"\(query)\""
                        showAlert = true
                    }
                }
            } catch {
                await MainActor.run {
                    isSearching = false
                    alertMessage = "Search failed: \(error.localizedDescription)"
                    showAlert = true
                }
            }
        }
    }

    private func selectDestination(_ result: GeocodingResult) {
        selectedDestination = result
        searchResults = []
        searchQuery = ""

        Task {
            await navEngine.startNavigation(
                to: result.coordinate,
                name: result.name.components(separatedBy: ",").first ?? result.name
            )
        }
    }

    // MARK: - Helpers

    private func maneuverIcon(_ maneuver: String) -> String {
        switch maneuver {
        case "turn_left", "sharp_left": return "arrow.turn.up.left"
        case "turn_right", "sharp_right": return "arrow.turn.up.right"
        case "slight_left": return "arrow.up.left"
        case "slight_right": return "arrow.up.right"
        case "continue": return "arrow.up"
        case "roundabout", "roundabout_exit": return "arrow.triangle.turn.up.right.circle"
        case "depart": return "location.fill"
        case "arrive": return "flag.fill"
        case "uturn": return "arrow.uturn.backward"
        default: return "arrow.up"
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        }
        return "\(Int(meters)) m"
    }
}

/// A compact map showing the route polyline, current position, and destination.
/// Used for the initial confirmation that the routing looks plausible.
struct RouteMapView: View {
    let route: [CLLocationCoordinate2D]
    let current: CLLocationCoordinate2D?
    let destination: CLLocationCoordinate2D?

    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $cameraPosition) {
            if let current {
                Annotation("You", coordinate: current) {
                    Image(systemName: "location.fill")
                        .foregroundColor(.blue)
                        .padding(4)
                        .background(Circle().fill(.white))
                }
            }
            if let destination {
                Annotation("Destination", coordinate: destination) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                }
            }
            MapPolyline(coordinates: route)
                .stroke(.blue, lineWidth: 4)
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { fitRoute() }
    }

    /// Fit the camera to the route bounds (plus current position and destination).
    private func fitRoute() {
        guard !route.isEmpty else { return }
        var minLat = route[0].latitude, maxLat = route[0].latitude
        var minLon = route[0].longitude, maxLon = route[0].longitude
        for c in route {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        for extra in [current, destination] {
            if let e = extra {
                minLat = min(minLat, e.latitude); maxLat = max(maxLat, e.latitude)
                minLon = min(minLon, e.longitude); maxLon = max(maxLon, e.longitude)
            }
        }
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let spanLat = max(maxLat - minLat, 0.002) * 1.3
        let spanLon = max(maxLon - minLon, 0.002) * 1.3
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )
        cameraPosition = .region(region)
    }
}

#Preview {
    ContentView()
        .environmentObject(NavigationEngine())
}
