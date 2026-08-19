# FenixNavi — Communication Protocol

## Phone → Watch Message Format

JSON sent from iOS app to Fenix 8 watch via `IQApp.sendMessage()`:

```json
{
  "type": "navigation_update",
  "step_index": 3,
  "total_steps": 12,
  "maneuver": "turn_right",
  "maneuver_text": "Turn right",
  "street_name": "Hauptstraße",
  "distance_m": 250,
  "duration_s": 45,
  "total_distance_km": 4.2,
  "total_duration_min": 18,
  "eta_min": 15
}
```

### Field Reference

| Field | Type | Description |
|---|---|---|
| `type` | string | Message type. `navigation_update` for turn instructions, `navigation_end` when destination reached, `rerouting` when recalculating. |
| `step_index` | int | Current step number (0-based) |
| `total_steps` | int | Total number of steps in the route |
| `maneuver` | string | Maneuver type of the **upcoming turn** (the maneuver at the end of the current step): `depart`, `turn_left`, `turn_right`, `slight_left`, `slight_right`, `sharp_left`, `sharp_right`, `continue`, `roundabout`, `roundabout_exit`, `arrive`, `uturn` |
| `maneuver_text` | string | Human-readable description of the **upcoming turn**, e.g. "Turn left onto Via Roma" |
| `street_name` | string | Name of the road you will turn **onto** (the upcoming step's road) |
| `distance_m` | int | Distance in meters until the upcoming turn (end of the current step) |
| `duration_s` | int | Duration in seconds until the upcoming turn |
| `turn_angle` | int | Relative turn angle of the **upcoming turn** in degrees (-180..180). 0=straight, +right, -left. |
| `wrong_direction` | bool | True when the user is heading the wrong way along the route (should turn around). |
| `total_distance_km` | float | Total remaining distance in km |
| `total_duration_min` | int | Total remaining time in minutes |
| `eta_min` | int | Estimated minutes to destination |

### Additional Message Types

```json
{ "type": "navigation_end" }
```
Shown when the user **arrives** at the destination.

```json
{ "type": "navigation_stopped" }
```
Shown when the user **cancels/stops** navigation on the phone — returns the watch to the waiting state (distinct from arrival).

```json
{ "type": "rerouting" }
```

## Watch → Phone Messages

```json
{ "type": "ack" }
```

Minimal — watch acknowledges receipt of messages, phone can use this to pace sends.

## Message Flow

```
Phone: Route calculated via OSRM
   │
   ▼
Phone: For each step, as user approaches turn (< 500m):
   │  sends navigation_update
   ▼
Watch: Displays turn info, vibrates if < 100m
   │
   ▼
Phone: When user passes turn waypoint → sends next step
   │
   ... repeats until arrival ...
   │
   ▼
Phone: sends navigation_end
   ▼
Watch: Shows "Arrived" screen
```
