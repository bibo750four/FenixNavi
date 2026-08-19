# FenixNavi — Turn-by-Turn Navigation on Garmin Fenix 8

**Send cycling navigation instructions from your iPhone to your Garmin Fenix 8 watch.**

FenixNavi is a two-part app:
- **iOS app** — Calculates cycling routes using free OpenStreetMap routing (OSRM), tracks your GPS position, and sends turn instructions to the watch.
- **Connect IQ watch app** — Displays turn-by-turn directions on your Fenix 8 AMOLED with arrows, distances, street names, and vibration alerts.

## Why FenixNavi?

On iOS, you can't get turn-by-turn navigation from Apple Maps, Google Maps, or CoMaps onto your Garmin watch — until now.

FenixNavi doesn't intercept other apps. It **is the navigation engine**: it calculates cycling routes using free OSM-based routing (OSRM), tracks your position, and pushes instructions directly to your watch via Bluetooth.

## Project Structure

```
FenixNavi/
├── README.md
├── FEASIBILITY_ASSESSMENT.md
├── docs/
│   └── communication-protocol.md
├── watch/                              # Connect IQ watch app (Monkey C)
│   ├── manifest.xml                    # App declaration, permissions, devices
│   ├── source/
│   │   ├── FenixNaviApp.mc             # App entry point, message handling
│   │   ├── FenixNaviView.mc            # Navigation UI layout
│   │   ├── FenixNaviDelegate.mc        # Button/touch handling
│   │   └── NavigationData.mc           # Data model for nav instructions
│   └── resources/
│       ├── strings/strings.xml         # Localized strings
│       └── drawables/launcher_icon.xml  # App icon
└── ios/                                # iOS companion app (Swift)
    └── FenixNavi/
        ├── FenixNaviApp.swift           # App entry point
        ├── ContentView.swift            # Main UI (search, navigate, status)
        ├── Info.plist                   # App configuration & permissions
        ├── Models/
        │   └── NavigationStep.swift      # Data model + OSRM response parsing
        ├── Navigation/
        │   ├── NavigationEngine.swift    # Core navigation logic
        │   └── RoutingService.swift      # OSRM API + Nominatim geocoding
        └── GarminBridge/
            └── GarminBridge.swift        # Connect IQ Companion SDK integration
```

## How It Works

```
iPhone (FenixNavi app)
  │
  ├─ Search destination (Nominatim geocoding)
  ├─ Calculate cycling route (OSRM routing API)
  ├─ Track GPS position (Core Location)
  ├─ Determine current turn step
  │
  └─ Send instructions via BLE ──────▶ Fenix 8 Watch
     (Connect IQ Companion SDK)        ┌──────────────────────┐
                                       │  ← Turn left          │
                                       │    250 m              │
                                       │    Hauptstraße        │
                                       │  ETA: 12 min         │
                                       └──────────────────────┘
```

### Routing

Uses the free, public [OSRM routing server](https://routing.openstreetmap.de/) sponsored by FOSSGIS:
- **Bike profile** with cycling-specific routing (prefers bike lanes, paths)
- **Worldwide** coverage, updated every ~2 days
- **No API key** required
- Rate limit: ~1 request/second (plenty for navigation use)
- Data: OpenStreetMap contributors

### Communication (Phone → Watch)

Messages are JSON-serialized dictionaries sent over BLE:

```json
{
  "type": "navigation_update",
  "maneuver": "turn_right",
  "maneuver_text": "Turn right onto Hauptstraße",
  "street_name": "Hauptstraße",
  "distance_m": 250,
  "eta_min": 15,
  "step_index": 3,
  "total_steps": 12,
  ...
}
```

Full protocol in [docs/communication-protocol.md](docs/communication-protocol.md).

## Prerequisites

### For the iOS App
- macOS with Xcode 16+
- iOS 17.6+ on iPhone
- [Connect IQ Companion SDK for iOS](https://github.com/garmin/connectiq-companion-app-sdk-ios) (add `ConnectIQ.xcframework` to Xcode)
- Garmin Connect Mobile installed on iPhone
- Apple Developer account (for device deployment)

### For the Watch App
- [Connect IQ SDK 9.2+](https://developer.garmin.com/connect-iq/sdk/)
- Visual Studio Code with [Monkey C extension](https://developer.garmin.com/connect-iq/sdk/)
- Garmin Fenix 8 AMOLED (or other compatible device)

## Setup

### 1. Watch App

1. Install the Connect IQ SDK and VS Code Monkey C extension
2. Open the `watch/` folder in VS Code
3. Generate a unique UUID for the app and update `manifest.xml`:
   ```xml
   <iq:application id="YOUR-UUID-HERE" ...>
   ```
4. Build: `Ctrl+Shift+P` → `Monkey C: Build for Device`
5. Sideload the `.iq` file to your Fenix 8 via Garmin Express or Connect IQ Store developer mode

### 2. iOS App

1. Clone/download the Connect IQ iOS SDK from [GitHub](https://github.com/garmin/connectiq-companion-app-sdk-ios)
2. Open the `ios/FenixNavi.xcodeproj` in Xcode (create the project if not yet set up)
3. Add `ConnectIQ.xcframework` to the project
4. In `GarminBridge.swift`, update `watchAppUUID` to match the UUID from `manifest.xml`
5. Select your iPhone as the target, build and run

### 3. Pair

1. Make sure Garmin Connect Mobile is running and your Fenix 8 is paired
2. Open the FenixNavi iOS app — it should auto-discover the watch
3. Open the FenixNavi app on the watch (it will be in the activities list)
4. The first connection may prompt for permission on the watch

## Usage

1. Open the **FenixNavi iOS app**
2. Wait for the watch connection indicator to turn green
3. **Search** for your destination (address, place name, coordinates)
4. Tap a result to **start navigation**
5. Keep your phone in your pocket — directions appear on your **Fenix 8**
6. The watch vibrates when approaching turns (< 100m)

## Watch App UI

| State | Display |
|---|---|
| **Waiting** | "FenixNavi" with connection status |
| **Navigating** | Direction arrow → maneuver text → distance → street name → ETA + progress |
| **Arrived** | Checkmark + "You have arrived!" |
| **Rerouting** | "Rerouting..." indicator |

## Known Limitations

- **iOS only** — Designed exclusively for iPhone + Garmin Fenix 8
- **Not a background app on watch** — The FenixNavi watch app must be in the foreground. You cannot simultaneously record a Garmin activity, but the Fenix 8 does track health metrics in the background.
- **Internet required** — The iOS app needs internet to calculate routes (OSRM API) and geocode addresses (Nominatim). Once a route is calculated, GPS-only navigation works offline.
- **Rate limits** — The public OSRM server limits to ~1 request/second. For heavy use, consider self-hosting OSRM or using GraphHopper's free tier (500 requests/day).
- **No turn-by-turn voice** on the watch — Vibration and visual only. Voice prompts come from the iPhone.
- **Sideloading** — The watch app must be sideloaded during development. App Store publishing requires Garmin review.

## Attribution

- Routing data: [OpenStreetMap contributors](https://www.openstreetmap.org/copyright)
- Routing engine: [OSRM](https://project-osrm.org/) (BSD license)
- Geocoding: [Nominatim](https://nominatim.org/) (ODbL)
- Watch platform: [Garmin Connect IQ](https://developer.garmin.com/connect-iq/)

## License

MIT License — see LICENSE file.
