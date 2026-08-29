// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// neutrinostdgeom.js - what the standard geometry properties say, against what
// the native window is actually doing.
//
// The question this branch exists to answer is whether an app can be written
// against `window.resizeTo` and `window.outerWidth` instead of against
// `neutrino.window.resize` and nothing at all. The write half is another file.
// This one is the read half, and it is first because it is also the apparatus:
// every later probe reports a number the page believes beside a number the
// harness measured, and none of those pairs mean anything until the harness is
// known to be reading a live window and to see it change.
//
// So the sequence is three samples with two known mutations between them, and
// the mutation is asked for through the API that already works. A run where the
// harness reads the same geometry at A and at B has not measured the engine's
// `outerWidth`; it has measured a window that never moved, or an instrument
// pointed at the wrong one. That is the positive control and it is the reason
// this file calls `neutrino.window.resize` rather than `window.resizeTo`.
//
// It also collects, for free, the number four drivers have been disagreeing
// about since they were written: `resize(640,480)` sets ClientSize on Windows,
// the outer frame on macOS, and the toplevel size on GTK and Qt. The delta
// between the request and each of the two measured sizes is what
// verify-linux.sh's fifty-pixel tolerance has been hiding.
//
// ES5 only, and `eval("window")` rather than the bare global: this same source
// is compiled by jsc.exe on Windows, where neither exists at compile time.
var win = eval("window");
var doc = eval("document");

// Read on the first statement of the app's own script, not later. Whether the
// API is there before an app's first line is a question step 4 of the plan
// turns into a documented guarantee or a documented exception, and the only
// moment it can be asked is this one -- a fifth of a second later every lane
// answers yes and the reading is worthless.
var NT0 = (typeof win.neutrino === "undefined") ? "no" : "yes";
var RS0 = "";
try { RS0 = String(doc.readyState); } catch (_) { RS0 = "threw"; }

// Each state is held long enough that the harness's recording loop cannot miss
// it on a busy runner. The verifier lifts this number out of this file and
// fails its own control if its slowest turn came within it -- a sampler that
// does not know the dwell is a coin toss, which cost four PRs on Windows.
var DWELL = 1500;

var REQ_W = 640;
var REQ_H = 480;
var REQ_X = 120;
var REQ_Y = 90;

// The window a phase asks for has to survive isDimension and isCoordinate or
// the message is dropped with no word to anybody, and a control that vanishes
// silently takes every reading after it down with it.
function num(v) {
    var n = Number(v);
    if (!isFinite(n)) { return "NaN"; }
    return String(Math.round(n * 100) / 100);
}

// A title over 1024 characters is refused by the splitter, and refused means
// the previous title stays up -- which reads from outside exactly like a phase
// that stalled. Nothing outside the page can tell those apart, so the guard is
// in here and an overflow becomes a reading instead of a silence.
function put(s) {
    var t = String(s);
    if (t.length > 1000) {
        t = "STD-OVER len=" + t.length + " " + t.substring(0, 900);
    }
    try { win.neutrino.window.setTitle(t); } catch (_) {}
}

// The engine, from the one string that names it. Not a finding -- it is what
// lets a reading in an annotation be attributed to a lane when six of them
// report the same field name.
function engine() {
    var ua = "";
    try { ua = String(win.navigator.userAgent || ""); } catch (_) { return "unknown"; }
    if (ua.indexOf("Edg") !== -1) { return "WebView2"; }
    if (ua.indexOf("QtWebEngine") !== -1) { return "QtWebEngine"; }
    if (ua.indexOf("Chrome") !== -1) { return "Chromium"; }
    if (ua.indexOf("Safari") !== -1) { return "WebKit"; }
    return "unknown";
}

// Everything the page believes about where it is. Every one of these is a
// diagnostic on its own: paired with the harness's own measurement of the same
// window it becomes a reading, and the verifier is what puts the two together.
function sample() {
    var out = "";
    try { out += " ow=" + num(win.outerWidth) + " oh=" + num(win.outerHeight); }
    catch (_) { out += " ow=threw oh=threw"; }
    try { out += " iw=" + num(win.innerWidth) + " ih=" + num(win.innerHeight); }
    catch (_) { out += " iw=threw ih=threw"; }
    try { out += " sx=" + num(win.screenX) + " sy=" + num(win.screenY); }
    catch (_) { out += " sx=threw sy=threw"; }
    try { out += " sw=" + num(win.screen.width) + " sh=" + num(win.screen.height); }
    catch (_) { out += " sw=threw sh=threw"; }
    try { out += " aw=" + num(win.screen.availWidth) + " ah=" + num(win.screen.availHeight); }
    catch (_) { out += " aw=threw ah=threw"; }
    try { out += " dpr=" + num(win.devicePixelRatio); } catch (_) { out += " dpr=threw"; }
    try {
        out += win.visualViewport
            ? (" vvw=" + num(win.visualViewport.width) + " vvh=" + num(win.visualViewport.height))
            : " vvw=none vvh=none";
    } catch (_) { out += " vvw=threw vvh=threw"; }
    return out;
}

function phaseA() {
    put("STD-GEOM-A-PAIR" + sample());
    win.setTimeout(phaseB, DWELL);
}

function phaseB() {
    try { win.neutrino.window.resize(REQ_W, REQ_H); } catch (_) {}
    // A frame for the toolkit to act on the request before the page is asked
    // what it thinks happened. Not a settling budget: the harness records the
    // native side continuously and does not depend on this.
    win.setTimeout(function () {
        put("STD-GEOM-B-PAIR req=" + REQ_W + "x" + REQ_H + sample());
        win.setTimeout(phaseC, DWELL);
    }, 250);
}

function phaseC() {
    try { win.neutrino.window.move(REQ_X, REQ_Y); } catch (_) {}
    win.setTimeout(function () {
        put("STD-GEOM-C-PAIR req=" + REQ_X + "," + REQ_Y + sample());
        win.setTimeout(phaseR, DWELL);
    }, 250);
}

// The two answers that are only about this document, marked so the verifier
// prints them and never asserts them. A page's own account of its state is a
// diagnostic; the instrument outside it is the reading.
function phaseR() {
    var tx = "none";
    try { tx = String(win.neutrino.transport); } catch (_) {}
    put("STD-GEOM-R-SELF eng=" + engine() + " nt0=" + NT0 + " rs0=" + RS0 +
        " tx=" + tx + " dwell=" + DWELL);
    win.setTimeout(function () { put("STD-GEOM-END"); }, DWELL);
}

// The wait is for the API and not for the body: this script is injected at
// document end, so the markup is parsed before its first statement, and what
// may not be there yet is the object every phase reports through. NT0 above has
// already recorded whether it was.
function ready() {
    if (win.neutrino) { phaseA(); }
    else { win.setTimeout(ready, 16); }
}

ready();
