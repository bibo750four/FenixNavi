using Toybox.Application;
using Toybox.Attention;
using Toybox.Communications;
using Toybox.Lang;
using Toybox.System;
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

    function initialize() {
        AppBase.initialize();
        _navData = new NavigationData();
        _navView = null;
        _messageCount = 0;
        _isConnected = false;
        _lastMessageTime = 0;
        _vibratedForStep = -1;
    }

    function onStart(state) {
        // Register for phone app messages
        Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
    }

    function onStop(state) {
        // Clean up
        Communications.registerForPhoneAppMessages(null);
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
}
