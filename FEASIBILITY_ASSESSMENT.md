# FenixNavi — Feasibility Assessment & Concept (iOS)

## Executive Summary

**Status: PROJECT INITIATED**

FenixNavi is an **iOS-only** solution for displaying turn-by-turn cycling navigation from an iPhone onto a Garmin Fenix 8 AMOLED watch. Since Apple does not allow third-party apps to intercept notifications from other apps, the approach is not to "read" existing navigation apps — instead, FenixNavi **is the navigation engine itself**. It calculates cycling routes using free OpenStreetMap-based routing (OSRM), tracks your GPS position, and pushes instructions directly to the Fenix 8 via the Connect IQ Companion SDK over Bluetooth.

**Project scaffolding is complete** — the Connect IQ watch app (Monkey C) and the iOS companion app (Swift) have been designed and initial source files created.

e---

## 1. The iOS Constraint

### Why Existing Navigation Apps Cannot Be Intercepted on iOS

| Reason | Detail |
|---|---|
| **No NotificationListenerService** | Android has `NotificationListenerService` to read any app's notifications. iOS has no equivalent — app notifications are fully sandboxed. |
| **Apple Maps private APIs** | Apple Maps uses private, undocumented notification APIs for turn-by-turn alerts. Not accessible to third-party developers. |
| **Google Maps on iOS** | Google Maps on iOS does not expose navigation data programmatically. Its notifications are plain text without structured data. |
| **CoMaps / Organic Maps** | Open source, so theoretically forkable, but adding a Garmin export feature means maintaining a C++/ObjC/Swift codebase fork — not practical for a small project. |

### The Chosen Approach: Built-In Navigation Engine

Rather than intercepting another app, FenixNavi's iOS app handles the entire navigation pipeline:

```
┌────────────────────────────────────────────────────────┐
│                    iOS App (FenixNavi)                  │
│                                                        │
│  ┌──────────────┐    ┌──────────────┐                  │
│  │  Search      │    │  OSRM        │                  │
│  │  (Nominatim) │───▶│  Routing API │  (free, no key)  │
│  └──────────────┘    └──────┬───────┘                  │
│                             │ route steps               │
│  ┌──────────────┐    ┌──────▼───────┐                  │
│  │  Core        │    │  Navigation  │                  │
│  │  Location    │◀──▶│  Engine      │                  │
│  │  (GPS)       │    │  (step track)│                  │
│  └──────────────┘    └──────┬───────┘                  │
│                             │ JSON messages             │
│                     ┌───────▼───────┐                  │
│                     │  GarminBridge │                  │
│                     │  (CIQ SDK)    │                  │
│                     └───────┬───────┘                  │
└─────────────────────────────┼──────────────────────────┘
                              │ BLE (via Garmin Connect)
                              ▼
              ┌───────────────────────────────┐
              │        Fenix 8 AMOLED         │
              │  ┌──────────────────────────┐ │
              │  │  ← Turn left             │ │
              │  │    250 m                 │ │
              │  │    Hauptstraße           │ │
              │  │  ETA: 12 min            │ │
              │  └──────────────────────────┘ │
              └───────────────────────────────┘
```

---

## 2. Technical Architecture

### 2.1 iOS App (Swift)

| Component | Technology | Purpose |
|---|---|---|
| **Search** | Nominatim API (free OSM geocoder) | Address/place search for destination |
| **Routing** | OSRM routed-bike (`routing.openstreetmap.de`) | Cycling route calculation with turn-by-turn steps |
| **GPS** | Core Location (background mode) | Real-time position tracking |
| **Step detection** | Haversine distance to step endpoints | Determine when user passes a turn waypoint |
| **Watch bridge** | Connect IQ Companion SDK for iOS | Send JSON nav updates over BLE |

**Key iOS entitlements:**
- `UIBackgroundModes: location` — enables GPS while phone is locked or app is backgrounded
- `NSBluetoothAlwaysUsageDescription` — for BLE communication with watch
- `LSApplicationQueriesSchemes: gcm-ciq` — allows launching Garmin Connect Mobile

### 2.2 Watch App (Monkey C / Connect IQ)

| Component | API | Purpose |
|---|---|---|
| **Message reception** | `Communications.registerForPhoneAppMessages()` | Receive JSON nav data from iOS |
| **UI rendering** | `WatchUi.View` + `Graphics.Dc` | Draw direction arrow, distance, street name, ETA, progress bar |
| **Haptic feedback** | `Attention.vibrate()` | Buzz when approaching turn (< 100m) |
| **Acknowledgment** | `Communications.transmit()` | Send ACK back to iOS |

**Watch app types:** Device App (`watch-app`) — must be in the foreground to receive messages continuously.

**Screen layout** (Fenix 8 AMOLED 47mm: 454×454 px):
```
┌─────────────────────────────┐
│                             │
│           ←                 │  ← Direction arrow (large Unicode glyph)
│                             │
│       Turn left             │  ← Maneuver text
│                             │
│        250 m                │  ← Distance to turn (large green number)
│       Hauptstraße           │  ← Road name
│                             │
│   ETA: 12 min  ·  4.2 km   │  ← Trip summary
│   ████████░░░░░░░░░░░░░░   │  ← Progress bar
│          3 / 12             │  ← Step counter
└─────────────────────────────┘
```

### 2.3 Communication Protocol

JSON messages sent from iOS to watch over BLE. Full spec in [docs/communication-protocol.md](docs/communication-protocol.md).

**Message types:**

| Type | Trigger | Effect on watch |
|---|---|---|
| `navigation_update` | iOS detects position change / new step | Update arrow, distance, street name, ETA |
| `navigation_end` | User arrives at destination | Show "Arrived" screen with checkmark |
| `rerouting` | Route recalculation in progress | Show "Rerouting..." indicator |

**Example message:**
```json
{
  "type": "navigation_update",
  "step_index": 3,
  "total_steps": 12,
  "maneuver": "turn_right",
  "maneuver_text": "Turn right onto Hauptstraße",
  "street_name": "Hauptstraße",
  "distance_m": 250,
  "duration_s": 45,
  "total_distance_km": 4.2,
  "total_duration_min": 18,
  "eta_min": 15
}
```

---

## 3. Routing Infrastructure

### Free OSRM Server (FOSSGIS-sponsored)

| Property | Value |
|---|---|
| **Bike endpoint** | `https://routing.openstreetmap.de/routed-bike/route/v1/bike/{lon},{lat};{lon},{lat}?steps=true&geometries=geojson` |
| **Coverage** | Worldwide |
| **Data freshness** | Updated every ~2 days from OpenStreetMap |
| **Rate limit** | ~1 request/second |
| **API key** | None required |
| **Cost** | Free (non-commercial use) |
| **Usage policy** | Display OSM attribution, use valid User-Agent, max 1 req/s |

### Alternative: GraphHopper Free Tier

If rate limits become an issue: 500 credits/day, 5 locations per request, cycling profile with elevation data. Requires registration but no credit card.

---

## 4. Project Structure

```
FenixNavi/
├── README.md
├── FEASIBILITY_ASSESSMENT.md          ← This file
├── docs/
│   └── communication-protocol.md
├── watch/                             ← Connect IQ watch app (Monkey C)
│   ├── manifest.xml
│   ├── source/
│   │   ├── FenixNaviApp.mc
│   │   ├── FenixNaviView.mc
│   │   ├── FenixNaviDelegate.mc
│   │   └── NavigationData.mc
│   └── resources/
│       ├── strings/strings.xml
│       └── drawables/launcher_icon.xml
└── ios/                               ← iOS companion app (Swift)
    └── FenixNavi/
        ├── FenixNaviApp.swift
        ├── ContentView.swift
        ├── Info.plist
        ├── Models/NavigationStep.swift
        ├── Navigation/
        │   ├── NavigationEngine.swift
        │   └── RoutingService.swift
        └── GarminBridge/GarminBridge.swift
```

---

## 5. Known Limitations & Risks

| Limitation | Impact | Mitigation |
|---|---|---|
| **Watch app must be in foreground** | Cannot record a Garmin activity simultaneously | Fenix 8 still tracks HR/steps in background; record ride separately if needed |
| **Internet required for route calculation** | Cannot start new routes without connectivity | Once calculated, GPS-only navigation works offline for the duration of the ride |
| **OSRM rate limit (1 req/s)** | Only one route calculation per second | Single-route navigation doesn't hit this; only matters for rapid re-routing |
| **OSRM public server availability** | Downtime possible | Consider self-hosting OSRM or using GraphHopper as fallback |
| **Connect IQ app must be sideloaded** | Extra step during development | Final app can be published to Connect IQ Store after Garmin review |
| **Battery drain** | GPS + BLE on iPhone, display on watch | Expected with any navigation app; bring a power bank for long rides |

---

## 6. What's Done & What Remains

### ✅ Completed
- Project architecture and design
- Communication protocol specification
- Connect IQ watch app source code (4 Monkey C files)
- iOS companion app source code (6 Swift files)
- Info.plist with all required permissions
- Manifest.xml with Fenix 8 device support

### 🔧 Remaining Setup Tasks
1. Generate real app UUID and update `manifest.xml` + `GarminBridge.swift`
2. Install Connect IQ SDK + VS Code Monkey C extension
3. Create Xcode project and add `ConnectIQ.xcframework`
4. Build and sideload watch app to Fenix 8
5. Build and run iOS app on iPhone 13
6. Test end-to-end: search → route → watch display → navigation
7. Create launcher icon PNG for watch

---

## 7. Next Steps

1. **Set up development toolchain** — Connect IQ SDK, Xcode, ConnectIQ.xcframework
2. **Generate UUIDs** — One for the watch app, update both codebases
3. **Build and test** — Side-load watch app, run iOS app, verify BLE communication
4. **Field test** — Real cycling navigation test
5. **Polish** — UI refinements, error handling, re-routing logic
6. **Publish** — Connect IQ Store (watch app) + App Store (iOS app, if desired)
