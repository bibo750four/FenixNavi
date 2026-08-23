using Toybox.Application;
using Toybox.Attention;
using Toybox.Communications;
using Toybox.Lang;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

//! FenixNavi - Receive turn-by-turn navigation instructions from the iOS companion app.
//! The iOS app handles routing (OSRM) and sends structured navigation updates
//! over BLE via the Connect IQ Companion SDK.

class FenixNaviApp extends Application.AppBase {

    hidden var _navData;
    hidden var _navView;
    hidden var _messageCount;
    hidden var _isConnected;
    hidden var _lastMessageTime;
    hidden var _vibratedForStep;
    hidden var _updateTimer;
    hidden var _demoMode;
    hidden var _demoIndex;
    hidden var _demoScenarios;
    hidden var _demoTimer;

    function initialize() {
        AppBase.initialize();
        _navData = new NavigationData();
        _navView = null;
        _messageCount = 0;
        _isConnected = false;
        _lastMessageTime = 0;
        _vibratedForStep = -1;
        _demoMode = false;
        _demoIndex = 0;
        _demoScenarios = [
            ["turn_left", "Turn left onto Via Roma", "Via Roma", 80, -90, false, 0, 0, 8, 3, 1.2],
            ["turn_right", "Turn right onto Corso Costantino Nigra", "Corso Costantino Nigra", 60, 90, false, 0, 1, 8, 4, 1.0],
            ["turn_left", "Bear left onto Via Torino", "Via Torino", 120, -45, false, 0, 2, 8, 5, 0.9],
            ["turn_right", "Sharp right onto Via Milano", "Via Milano", 30, 135, false, 0, 3, 8, 2, 0.5],
            ["roundabout", "Roundabout, take exit 2 onto Via del Crist", "Via del Crist", 50, 0, false, 2, 4, 8, 4, 0.8],
            ["uturn", "Turn around", "", 60, 180, true, 0, 5, 8, 2, 0.6],
            ["continue", "Continue on Via delle Germane", "Via delle Germane", 150, 0, false, 0, 6, 8, 6, 1.5],
            ["arrive", "Arrive at destination", "", 20, 0, false, 0, 7, 8, 1, 0.1]
        ];
    }

    function onStart(state) {
        // Register for phone app messages
        Communications.registerForPhoneAppMessages(method(:onPhoneMessage));

        // Periodically refresh the view so the connection timeout is enforced
        // even when no messages arrive (e.g. after the phone app is closed).
        _updateTimer = new Timer.Timer();
        _updateTimer.start(method(:onTimeout), 10000, true);

        // Auto demo: when on the waiting screen with no phone, cycle through
        // the demo scenarios so the screens can be validated without buttons.
        _demoTimer = new Timer.Timer();
        _demoTimer.start(method(:onDemoTick), 4000, true);
    }

    function onStop(state) {
        // Clean up
        Communications.registerForPhoneAppMessages(null);
        if (_updateTimer != null) {
            _updateTimer.stop();
            _updateTimer = null;
        }
        if (_demoTimer != null) {
            _demoTimer.stop();
            _demoTimer = null;
        }
    }

    function onDemoTick() as Void {
        // Only run on the waiting screen (no active navigation).
        if (_navData.state == NavigationData.STATE_WAITING) {
            if (!_demoMode) {
                enterDemoMode();
            } else {
                nextDemoScenario();
            }
        }
    }

    function onTimeout() as Void {
        // Only refresh while navigating, so the view can detect a stale
        // connection and return to the waiting screen.
        if (_navData != null &&
            (_navData.state == NavigationData.STATE_NAVIGATING ||
             _navData.state == NavigationData.STATE_REROUTING)) {
            WatchUi.requestUpdate();
        }
    }

    function getInitialView() {
        _navView = new FenixNaviView(_navData);
        return [_navView, new FenixNaviDelegate()];
    }

    //! Callback when a message is received from the iOS companion app.
    //! @param msg The PhoneAppMessage containing JSON navigation data.
    function onPhoneMessage(msg as Communications.PhoneAppMessage) as Void {
        _lastMessageTime = System.getTimer();
        _isConnected = true;
        _messageCount++;

        if (msg.data == null) {
            System.println("FenixNavi: Received null message data");
            return;
        }

        var data = msg.data as Lang.Dictionary;

        if (data == null) {
            System.println("FenixNavi: Message missing 'type' field");
            return;
        }

        var msgType = data["type"];
        if (msgType == null) {
            System.println("FenixNavi: Message missing 'type' field");
            return;
        }

        // A real phone message means we're navigating for real - leave demo mode.
        if (_demoMode) {
            exitDemoMode();
        }

        if (msgType.equals("navigation_update")) {
            _navData.update(data);
            WatchUi.requestUpdate();

            // Vibrate only once per step, when the turn threshold is first crossed.
            // (The iOS app sends updates every ~2s; without this the watch buzzes constantly.)
            var distance = _navData.distanceMeters;
            if (distance != null && distance <= 100 && _vibratedForStep != _navData.stepIndex) {
                _vibratedForStep = _navData.stepIndex;
                Attention.vibrate([new Attention.VibeProfile(100, 200)]);
            }

        } else if (msgType.equals("navigation_end")) {
            _navData.clear();
            _navData.state = NavigationData.STATE_ARRIVED;
            WatchUi.requestUpdate();

            // Arrival vibration pattern
            Attention.vibrate([
                new Attention.VibeProfile(100, 150),
                new Attention.VibeProfile(0, 100),
                new Attention.VibeProfile(100, 150)
            ]);

        } else if (msgType.equals("navigation_stopped")) {
            // User stopped navigation on the phone - return to waiting state
            _navData.clear();
            _navData.state = NavigationData.STATE_WAITING;
            WatchUi.requestUpdate();
        } else if (msgType.equals("rerouting")) {
            _navData.state = NavigationData.STATE_REROUTING;
            WatchUi.requestUpdate();
        }

        // Send acknowledgment back to phone
        Communications.transmit("ack", null, new Communications.ConnectionListener());
    }

    function getNavData() {
        return _navData;
    }

    function getLastMessageTime() {
        return _lastMessageTime;
    }

    function isConnected() {
        var now = System.getTimer();
        // Consider disconnected if no message in the last 30 seconds
        if (now - _lastMessageTime > 30000 && _lastMessageTime != 0) {
            _isConnected = false;
        }
        return _isConnected;
    }

    //! Whether the in-app demo mode is active.
    function isDemoMode() {
        return _demoMode;
    }

    //! Enter demo mode and show the first scenario.
    function enterDemoMode() {
        _demoMode = true;
        _demoIndex = 0;
        applyDemoScenario();
        WatchUi.requestUpdate();
    }

    //! Advance to the next demo scenario (wraps around).
    function nextDemoScenario() {
        _demoIndex = (_demoIndex + 1) % _demoScenarios.size();
        applyDemoScenario();
        WatchUi.requestUpdate();
    }

    //! Leave demo mode and return to the waiting screen.
    function exitDemoMode() {
        _demoMode = false;
        _navData.clear();
        _navData.state = NavigationData.STATE_WAITING;
        WatchUi.requestUpdate();
    }

    //! Apply the current demo scenario to the nav data model.
    function applyDemoScenario() {
        var s = _demoScenarios[_demoIndex];
        _navData.setDemo(s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10]);
    }
}
