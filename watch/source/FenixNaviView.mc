using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Math;
using Toybox.System;
using Toybox.WatchUi;

//! Main view for the FenixNavi watch app.
//! Round-screen design: circular progress ring around the edge shrinks as the
//! distance to the next turn decreases. Center shows arrow + maneuver text
//! (wrapped to 2 lines, constrained to screen), ETA and distance below.
class FenixNaviView extends WatchUi.View {

    hidden var _navData;
    hidden var _centerX;
    hidden var _centerY;
    hidden var _width;
    hidden var _height;
    hidden var _ringRadius;
    hidden var _maxTextWidth;

    // Distance at which the ring is full (meters)
    static const RING_MAX_DIST = 500;

    function initialize(navData) {
        View.initialize();
        _navData = navData;
    }

    function onLayout(dc) {
        _width = dc.getWidth();
        _height = dc.getHeight();
        _centerX = _width / 2;
        _centerY = _height / 2;
        _ringRadius = (_width / 2) - 12;  // near the edge of the round screen
        _maxTextWidth = _width - 120;     // conservative, keep text inside the ring
    }

    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var state = _navData.state;

        // If navigating but no message from the phone for a while (e.g. the app
        // was closed), return to the waiting screen instead of staying stuck.
        if (state == NavigationData.STATE_NAVIGATING || state == NavigationData.STATE_REROUTING) {
            var app = Application.getApp();
            if (app != null && !app.isConnected()) {
                _navData.state = NavigationData.STATE_WAITING;
                state = NavigationData.STATE_WAITING;
            }
        }

        if (state == NavigationData.STATE_WAITING) {
            drawWaitingScreen(dc);
        } else if (state == NavigationData.STATE_NAVIGATING) {
            drawNavigationScreen(dc);
        } else if (state == NavigationData.STATE_ARRIVED) {
            drawArrivedScreen(dc);
        } else if (state == NavigationData.STATE_REROUTING) {
            drawReroutingScreen(dc);
        }
    }

    function drawWaitingScreen(dc) {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.drawText(_centerX, _centerY - 60, Graphics.FONT_LARGE,
                    "FenixNavi", Graphics.TEXT_JUSTIFY_CENTER);

        var app = Application.getApp();
        var msg = (app != null && app.isConnected())
            ? WatchUi.loadResource(Rez.Strings.WaitingForRoute)
            : WatchUi.loadResource(Rez.Strings.StartNavOnPhone);
        dc.drawText(_centerX, _centerY + 10, Graphics.FONT_SMALL, msg,
                    Graphics.TEXT_JUSTIFY_CENTER);

        dc.setPenWidth(2);
        dc.setColor((app != null && app.isConnected()) ? Graphics.COLOR_GREEN : Graphics.COLOR_RED,
                    Graphics.COLOR_BLACK);
        dc.fillCircle(_centerX, _centerY + 80, 6);

        // Demo mode hint
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_BLACK);
        dc.drawText(_centerX, _centerY + 95, Graphics.FONT_XTINY,
                    "Menu = demo mode", Graphics.TEXT_JUSTIFY_CENTER);
    }

    function drawNavigationScreen(dc) {
        // --- Circular progress ring around the edge ---
        var dist = (_navData.distanceMeters == null) ? 0.0 : _navData.distanceMeters.toFloat();
        // Ring: full at 150m, empty at 5m, so it visibly shrinks as you approach.
        var fraction = (dist - 5.0) / 145.0;
        if (fraction > 1.0) { fraction = 1.0; }
        if (fraction < 0.0) { fraction = 0.0; }

        var startAngle = 90;
        var sweep = 360 * fraction;

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_BLACK);
        dc.drawArc(_centerX, _centerY, _ringRadius, startAngle, startAngle + 360, 10);

        if (sweep > 0) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_BLACK);
            dc.drawArc(_centerX, _centerY, _ringRadius, startAngle, startAngle + sweep, 10);
        }

        // --- Center content ---
        // Direction arrow (light blue, thicker) - drawn at the actual turn angle.
        // If going the wrong way, show a U-turn (down) arrow.
        var arrowAngle = getArrowAngle(_navData.turnAngle);
        var maneuverText = _navData.maneuverText;
        if (_navData.wrongDirection) {
            arrowAngle = 180;  // point down = turn around
            maneuverText = "Turn around";
        }
        // Distance to next turn - placed near the top, close to the green arc
        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_BLACK);
        dc.drawText(_centerX, _centerY - 167, Graphics.FONT_XTINY,
                    Lang.format("$1$ to turn", [_navData.distanceText()]),
                    Graphics.TEXT_JUSTIFY_CENTER);

        if (_navData.maneuver != null && _navData.maneuver.equals("roundabout")) {
            drawRoundabout(dc, _centerX, _centerY - 100, 42, arrowAngle, _navData.roundaboutExit);
        } else {
            dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_BLACK);
            drawArrow(dc, _centerX, _centerY - 100, 42, arrowAngle);
        }

        // Maneuver instruction - wrapped to up to 3 lines so road names fit.
        // Uses the smallest font so descenders (p, g, y) aren't clipped and
        // lines have more breathing room.
        var lines = wrapText(dc, maneuverText, Graphics.FONT_XTINY, _maxTextWidth, 3);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        var lineY = _centerY - 50;
        for (var i = 0; i < lines.size(); i++) {
            dc.drawText(_centerX, lineY, Graphics.FONT_XTINY, lines[i],
                        Graphics.TEXT_JUSTIFY_CENTER);
            lineY += 44;
        }

        // ETA (small, moved down with the destination to leave room for the
        // third line of the maneuver text)
        var eta = (_navData.etaMin == null) ? 0 : _navData.etaMin;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.drawText(_centerX, _centerY + 74, Graphics.FONT_XTINY,
                    Lang.format("ETA: $1$ min", [eta]),
                    Graphics.TEXT_JUSTIFY_CENTER);

        // Distance to destination - two lines, lower on the screen
        var toDestKm = (_navData.totalDistanceKm == null) ? 0.0 : _navData.totalDistanceKm;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_BLACK);
        dc.drawText(_centerX, _centerY + 112, Graphics.FONT_XTINY,
                    Lang.format("$1$ km", [toDestKm.format("%.1f")]),
                    Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(_centerX, _centerY + 151, Graphics.FONT_XTINY,
                    "to destination",
                    Graphics.TEXT_JUSTIFY_CENTER);
    }

    function drawArrivedScreen(dc) {
        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_BLACK);
        dc.drawArc(_centerX, _centerY, _ringRadius, 90, 450, 10);
        drawArrow(dc, _centerX, _centerY - 40, 45, 0);
        dc.drawText(_centerX, _centerY + 40, Graphics.FONT_MEDIUM,
                    WatchUi.loadResource(Rez.Strings.Arrived),
                    Graphics.TEXT_JUSTIFY_CENTER);
    }

    function drawReroutingScreen(dc) {
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_BLACK);
        dc.drawText(_centerX, _centerY, Graphics.FONT_MEDIUM,
                    WatchUi.loadResource(Rez.Strings.Rerouting),
                    Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! Wrap text into up to 2 lines that each fit within maxWidth.
    //! Long words are truncated with "..." so text never exceeds the boundary.
    function wrapText(dc, text, font, maxWidth, maxLines) {
        var lines = [];
        if (text == null) { return lines; }
        var str = text as Lang.String;
        if (str.length() == 0) { return lines; }

        if (maxLines == null) { maxLines = 2; }

        // Character cap as a safety net - force wrapping for longer text
        var maxChars = 20;
        if (maxChars < 8) { maxChars = 8; }

        var words = splitWords(str);
        var current = "";
        for (var i = 0; i < words.size(); i++) {
            var test = (current.length() == 0) ? words[i] : current + " " + words[i];
            var tooWide = dc.getTextWidthInPixels(test, font) > maxWidth;
            var tooLong = test.length() > maxChars;
            if (!tooWide && !tooLong) {
                current = test;
            } else {
                if (current.length() > 0) {
                    lines.add(current);
                    if (lines.size() >= maxLines) { break; }
                }
                current = words[i];
            }
        }
        if (current.length() > 0 && lines.size() < maxLines) {
            lines.add(current);
        }

        // Truncate any line that is still too wide
        for (var j = 0; j < lines.size(); j++) {
            lines[j] = truncateToFit(dc, lines[j], font, maxWidth);
        }
        return lines;
    }

    //! Split a string into words on spaces (String.split is not available).
    function splitWords(str) {
        var words = [];
        var current = "";
        for (var i = 0; i < str.length(); i++) {
            var ch = str.substring(i, i + 1);
            if (ch.equals(" ")) {
                if (current.length() > 0) {
                    words.add(current);
                    current = "";
                }
            } else {
                current = current + ch;
            }
        }
        if (current.length() > 0) {
            words.add(current);
        }
        return words;
    }

    //! Truncate a single line with "..." so it fits within maxWidth.
    function truncateToFit(dc, text, font, maxWidth) {
        if (dc.getTextWidthInPixels(text, font) <= maxWidth) { return text; }
        var result = text;
        while (result.length() > 0 &&
               dc.getTextWidthInPixels(result + "\u2026", font) > maxWidth) {
            result = result.substring(0, result.length() - 1);
        }
        return result + "\u2026";
    }

    //! Draw a direction arrow using graphics primitives.
    //! The head is a filled triangle so the tip renders cleanly (not clipped).
    function drawArrow(dc, cx, cy, size, angle) {
        var rad = angle * Math.PI / 180.0;
        var tipX = cx + size * Math.sin(rad);
        var tipY = cy - size * Math.cos(rad);
        var tailX = cx - size * 0.5 * Math.sin(rad);
        var tailY = cy + size * 0.5 * Math.cos(rad);

        // Shaft (thinner so the head is clearly visible)
        dc.setPenWidth(7);
        dc.drawLine(tailX, tailY, tipX, tipY);

        // Filled triangular head, larger than the shaft width so it reads as
        // an arrowhead (fillPolygon takes an array of [x, y] points)
        var headLen = size * 0.42;
        var headWidth = size * 0.36;
        var bx = tipX - headLen * Math.sin(rad);
        var by = tipY + headLen * Math.cos(rad);
        var p1x = bx + headWidth * Math.cos(rad);
        var p1y = by + headWidth * Math.sin(rad);
        var p2x = bx - headWidth * Math.cos(rad);
        var p2y = by - headWidth * Math.sin(rad);
        dc.fillPolygon([[tipX, tipY], [p1x, p1y], [p2x, p2y]]);
    }

    //! Draw a roundabout glyph: a circle with the exit arrow and the exit number.
    function drawRoundabout(dc, cx, cy, size, angle, exit) {
        // Roundabout circle
        dc.setPenWidth(4);
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_BLACK);
        dc.drawCircle(cx, cy, size);

        // Exit arrow inside the circle (angle is the exit direction)
        var rad = angle * Math.PI / 180.0;
        var tipX = cx + size * 0.6 * Math.sin(rad);
        var tipY = cy - size * 0.6 * Math.cos(rad);
        var tailX = cx - size * 0.2 * Math.sin(rad);
        var tailY = cy + size * 0.2 * Math.cos(rad);

        dc.setPenWidth(6);
        dc.drawLine(tailX, tailY, tipX, tipY);

        // Arrowhead
        var headLen = size * 0.22;
        var headWidth = size * 0.18;
        var bx = tipX - headLen * Math.sin(rad);
        var by = tipY + headLen * Math.cos(rad);
        var p1x = bx + headWidth * Math.cos(rad);
        var p1y = by + headWidth * Math.sin(rad);
        var p2x = bx - headWidth * Math.cos(rad);
        var p2y = by - headWidth * Math.sin(rad);
        dc.fillPolygon([[tipX, tipY], [p1x, p1y], [p2x, p2y]]);

        // Exit number at the center
        if (exit != null && exit > 0) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
            dc.drawText(cx, cy, Graphics.FONT_XTINY, exit.toString(),
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    //! Convert the relative turn angle (degrees, 0=straight, +right, -left)
    //! into a drawArrow angle (0=up, 90=right, 180=down, 270=left).
    function getArrowAngle(turnAngle) {
        if (turnAngle == null) { return 0; }
        // Convert to an integer Number first: the % operator in Monkey C throws
        // an exception when applied to a Float/Double, so we normalize on a Number.
        var angle = turnAngle.toNumber();
        // Normalize to 0..360
        angle = angle % 360;
        if (angle < 0) { angle += 360; }
        // Near 180 => U-turn (point down)
        if (angle > 150 && angle < 210) { return 180; }
        return angle.toFloat();
    }
}
