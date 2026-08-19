import SwiftUI
import CoreLocation

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
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "bicycle")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
                Text("Cycle Navigation")
                    .font(.title2.bold())
                Text("to Garmin Watch")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 30)

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

            if isSearching {
                ProgressView("Searching...")
                    .padding()
            }

            // Search results
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
            // Current instruction
            if let step = navEngine.currentStep {
                VStack(spacing: 16) {
                    // Maneuver icon
                    Image(systemName: maneuverIcon(step.maneuver))
                        .font(.system(size: 56))
                        .foregroundColor(.green)

                    // Instruction text
                    Text(step.instruction)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    // Distance to turn
                    Text(formatDistance(step.distance))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                }
                .padding(.top, 30)

                // Street name
                if !step.streetName.isEmpty {
                    Text(step.streetName)
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
            }

            // Re-routing indicator
            if navEngine.isRerouting {
                ProgressView("Rerouting...")
                    .padding()
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

#Preview {
    ContentView()
        .environmentObject(NavigationEngine())
}
