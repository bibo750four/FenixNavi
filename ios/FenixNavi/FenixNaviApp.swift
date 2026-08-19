import SwiftUI

/// FenixNavi iOS Companion App
///
/// Entry point for the iOS app that handles routing (via OSRM) and sends
/// turn-by-turn navigation instructions to a Garmin Fenix 8 watch via
/// the Connect IQ Companion SDK.

@main
struct FenixNaviApp: App {
    @StateObject private var navigationEngine = NavigationEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(navigationEngine)
                .onOpenURL { url in
                    // Handle return from Garmin Connect Mobile device selection
                    if url.scheme == GarminBridge.urlScheme {
                        navigationEngine.handleGarminURL(url)
                    }
                }
        }
    }
}
