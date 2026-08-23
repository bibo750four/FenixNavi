using Toybox.WatchUi;

//! Input delegate for FenixNavi. Handles button presses and touch events.
class FenixNaviDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    // Back button exits the app
    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }

    // Menu button can be used to show settings (future)
    function onMenu() {
        // Reserved for future settings menu
        return true;
    }
}
