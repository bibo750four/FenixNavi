using Toybox.Application;
using Toybox.WatchUi;

//! Input delegate for FenixNavi. Handles button presses and touch events.
class FenixNaviDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    // Back button: exits demo mode if active, otherwise exits the app.
    function onBack() {
        var app = Application.getApp();
        if (app != null && app.isDemoMode()) {
            app.exitDemoMode();
            return true;
        }
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }

    // Menu button: enters demo mode, or advances to the next demo scenario.
    function onMenu() {
        var app = Application.getApp();
        if (app != null) {
            if (app.isDemoMode()) {
                app.nextDemoScenario();
            } else {
                app.enterDemoMode();
            }
        }
        return true;
    }
}
