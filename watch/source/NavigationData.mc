using Toybox.Lang;

//! Navigation data model. Holds the current turn-by-turn instruction
//! received from the iOS companion app.
class NavigationData {

    // Navigation states
    static const STATE_WAITING = 0;
    static const STATE_NAVIGATING = 1;
    static const STATE_ARRIVED = 2;
    static const STATE_REROUTING = 3;

    var state;
    var stepIndex;
    var totalSteps;
    var maneuver;
    var maneuverText;
    var streetName;
    var distanceMeters;
    var durationSeconds;
    var totalDistanceKm;
    var totalDurationMin;
    var etaMin;
    var turnAngle;
    var wrongDirection;
    var roundaboutExit;

    function initialize() {
        clear();
    }

    function clear() {
        state = STATE_WAITING;
        stepIndex = 0;
        totalSteps = 0;
        maneuver = "";
        maneuverText = "";
        streetName = "";
        distanceMeters = 0;
        durationSeconds = 0;
        totalDistanceKm = 0.0;
        totalDurationMin = 0;
        etaMin = 0;
        turnAngle = 0;
        wrongDirection = false;
        roundaboutExit = 0;
    }

    //! Update from a dictionary received via PhoneAppMessage.
    function update(data as Lang.Dictionary) {
        state = STATE_NAVIGATING;

        var v;
        v = data["step_index"];          if (v != null) { stepIndex = v; }
        v = data["total_steps"];         if (v != null) { totalSteps = v; }
        v = data["maneuver"];            if (v != null) { maneuver = v; }
        v = data["maneuver_text"];       if (v != null) { maneuverText = v; }
        v = data["street_name"];         if (v != null) { streetName = v; }
        v = data["distance_m"];          if (v != null) { distanceMeters = v; }
        v = data["duration_s"];          if (v != null) { durationSeconds = v; }
        v = data["total_distance_km"];   if (v != null) { totalDistanceKm = v; }
        v = data["total_duration_min"];  if (v != null) { totalDurationMin = v; }
        v = data["eta_min"];             if (v != null) { etaMin = v; }
        v = data["turn_angle"];          if (v != null) { turnAngle = v; }
        v = data["wrong_direction"];     if (v != null) { wrongDirection = v; }
        v = data["exit"];                if (v != null) { roundaboutExit = v; }
    }

    //! Populate the model with a fixed demo scenario (for the in-app demo mode).
    function setDemo(maneuver, maneuverText, streetName, distanceMeters, turnAngle,
                     wrongDirection, roundaboutExit, stepIndex, totalSteps,
                     etaMin, totalDistanceKm) {
        state = STATE_NAVIGATING;
        self.maneuver = maneuver;
        self.maneuverText = maneuverText;
        self.streetName = streetName;
        self.distanceMeters = distanceMeters;
        self.turnAngle = turnAngle;
        self.wrongDirection = wrongDirection;
        self.roundaboutExit = roundaboutExit;
        self.stepIndex = stepIndex;
        self.totalSteps = totalSteps;
        self.etaMin = etaMin;
        self.totalDistanceKm = totalDistanceKm;
    }

    //! Get a human-readable distance string.
    function distanceText() {
        if (distanceMeters == null) { return "0 m"; }
        if (distanceMeters >= 1000) {
            var km = distanceMeters / 1000.0;
            return Lang.format("$1$.$2$ km", [km.toNumber(), (km * 10).toNumber() % 10]);
        }
        return Lang.format("$1$ m", [distanceMeters]);
    }
}
