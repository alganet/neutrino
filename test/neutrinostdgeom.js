// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// neutrinostdgeom.js - what the standard geometry properties say, against what
// the native window is actually doing.
//
// The question this branch exists to answer is whether an app can be written
// against `window.resizeTo` and `window.outerWidth` instead of against
// `neutrino.window.resize` and nothing at all -- and now it can. The write
// half is another file.
// This one is the read half, and it is first because it is also the apparatus:
// every later probe reports a number the page believes beside a number the
// harness measured, and none of those pairs mean anything until the harness is
// known to be reading a live window and to see it change.
//
// So the sequence is three samples with two known mutations between them, and
// the mutation is asked for through the launcher's own API. A run where the
// harness reads the same geometry at A and at B has not measured the engine's
// `outerWidth`; it has measured a window that never moved, or an instrument
// pointed at the wrong one. That is the positive control.
//
// It used to call `neutrino.window.resize` here precisely because that was a
// different call from the one under test. It is not any more: the launcher
// writes over `window.resizeTo` now, so the control and the standard spelling
// are one call, and these mutations double as the assertion that the spelling
// works. What that no longer separates is "the engine refused" from "the
// window is dead" -- and a window which refuses all of them is a regression
// on either reading, which is why the verifier still fails on it.
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
    doc.title = t;
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
    // WKWebView, which carries neither "Safari" nor any of the three above.
    // Added from a measurement and not from a guess: the previous round made
    // this branch print what it had actually read, and the macOS lane came back
    // `unknown[Mozilla/5.0 Macintosh Intel Mac OS X 10157 Apple]` -- an
    // AppleWebKit user agent with no product token on the end, because nothing
    // sets applicationNameForUserAgent. Last of the WebKit tests, so the three
    // engines above that also carry "AppleWebKit" have already been named.
    if (ua.indexOf("AppleWebKit") !== -1) { return "WebKit"; }
    // Not "unknown". The macOS lane has answered `eng=unknown` fifteen times a
    // run for as long as this function has existed -- WKWebView's user agent
    // does not carry any of the four names above -- and "unknown" is the one
    // reply that cannot be acted on: it does not say whether the string was
    // empty, or absent, or simply unrecognised. A slice of what was actually
    // read turns the next run into the measurement that settles it.
    //
    // Safe to change: nothing in any verifier matches on `eng=`, so this is
    // read by people and not by assertions.
    return ua === "" ? "unknown-empty-ua"
        : "unknown[" + ua.replace(/[^A-Za-z0-9.\/ ]/g, "").substring(0, 48) + "]";
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

// ------------------------------------------------------------------- the face
//
// The same reason the theme probe has one, and one more that is specific to
// this pair. Both halves of the decoration differential render the early
// shell's "Welcome to neutrino" and nothing else, and the capture is now a
// crop of the window rather than a photograph of the desktop -- so the only
// thing separating `frame-decorated.png` from `frame-chromeless.png` in a
// sheet is the presence of a title bar, and a reader with one of them in front
// of them cannot tell a chromeless window from a decorated one whose bar was
// cropped off. The page has to say which build it is.
//
// Painted at STD-GEOM-END, which is the state the verifier photographs, and
// after every phase has reported. Nothing here is asserted: `outerWidth` and
// the rest go out through the title as -PAIR values, and this reprints them
// for the human rather than adding a reading.
function faceRow(k, v) {
    return '<tr><td style="padding:1px 12px 1px 0;opacity:.6">' + k +
        '</td><td style="padding:1px 0">' + v + '</td></tr>';
}

function paint() {
    try {
        // Measured, not claimed. `decorations` is a host-side config key --
        // `undecorated()` lives in the launcher and the page's `neutrino`
        // object carries only {transport, theme, _theme} -- so there is nothing
        // here to read it from. The first draft of this face queried a
        // `neutrino-decorations` meta tag that does not exist and would have
        // printed "auto" on both halves: a caption that is confidently wrong is
        // worse on a verification sheet than no caption at all.
        //
        // Outer minus inner is what the frame costs, which is the thing the
        // differential asserts and the one fact that distinguishes the halves.
        var dw = "?", dh = "?", verdict = "unreadable";
        try {
            var ow = num(win.outerWidth), oh = num(win.outerHeight);
            var iw = num(win.innerWidth), ih = num(win.innerHeight);
            dw = String(ow - iw);
            dh = String(oh - ih);
            verdict = (ow - iw === 0 && oh - ih === 0)
                ? "no frame measured -- this window is chromeless"
                : "a frame of " + dw + " x " + dh + " around the viewport";
        } catch (_) {}

        var body = doc.body;
        body.style.margin = "0";
        body.style.padding = "12px 14px";
        body.style.background = "var(--neutrino-Canvas, Canvas)";
        body.style.color = "var(--neutrino-CanvasText, CanvasText)";
        body.style.font = "13px/1.5 system-ui, sans-serif";
        body.style.boxSizing = "border-box";
        body.style.minHeight = "100vh";
        // A ruled edge all the way round the viewport. On the chromeless build
        // this line *is* the window's edge, which is the whole claim that half
        // makes; on the decorated build there is a title bar and a border
        // outside it. One picture each, and they are not confusable.
        body.style.border = "2px dashed var(--neutrino-Highlight, Highlight)";

        var h = '<div style="font:600 15px/1.3 system-ui,sans-serif">GEOMETRY &middot; ' +
            engine() + '</div>' +
            '<div style="font:600 13px/1.5 monospace;margin:6px 0 10px">' +
            verdict + '</div>' +
            '<table style="font:12px/1.5 monospace;border-collapse:collapse">';
        h += faceRow("outer", num(win.outerWidth) + " x " + num(win.outerHeight));
        h += faceRow("inner", num(win.innerWidth) + " x " + num(win.innerHeight));
        h += faceRow("frame costs", dw + " x " + dh);
        h += faceRow("screen at", num(win.screenX) + ", " + num(win.screenY));
        h += faceRow("dpr", num(win.devicePixelRatio));
        h += '</table>' +
            '<div style="font:11px/1.4 monospace;opacity:.55;margin-top:10px">' +
            'the dashed rule is the edge of the viewport</div>';
        body.innerHTML = h;
    } catch (_) {
        // A face that throws must not take the probe with it.
    }
}

function phaseA() {
    put("STD-GEOM-A-PAIR" + sample());
    win.setTimeout(phaseB, DWELL);
}

function phaseB() {
    try { win.resizeTo(REQ_W, REQ_H); } catch (_) {}
    // A frame for the toolkit to act on the request before the page is asked
    // what it thinks happened. Not a settling budget: the harness records the
    // native side continuously and does not depend on this.
    win.setTimeout(function () {
        put("STD-GEOM-B-PAIR req=" + REQ_W + "x" + REQ_H + sample());
        win.setTimeout(phaseC, DWELL);
    }, 250);
}

function phaseC() {
    try { win.moveTo(REQ_X, REQ_Y); } catch (_) {}
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
    win.setTimeout(function () { paint(); put("STD-GEOM-END"); }, DWELL);
}

// The wait is for both, and it used to be for the API alone on the grounds that
// this script is injected at document end so the markup is already parsed. That
// is true on three lanes and false on WebView2, where the first statement runs
// at `loading` -- and it stopped being a harmless inaccuracy the day this suite
// began reporting through `document.title`, because a title written before
// `<head>` exists is a no-op by the DOM's own rule and phase A went missing.
// NT0 and RS0 above are read at the first statement and are unaffected by the
// wait; they are what says which lane this is.
// One dwell of head start before the first state, and it is scaffolding for the
// instrument rather than anything about the geometry.
//
// The verifier attaches by finding a window, and a window exists before this
// script has said anything in it. On Windows that gap is wide and variable --
// `verify-std.ps1` compiles its interop types with Add-Type before it can poll
// at all -- so the race is between this app reaching STD-GEOM-B-PAIR and the
// recorder starting. Measured across four runs of `windows-content`: the
// recorder caught A at 169ms, 959ms and 1103ms, and on the fourth it opened on
// B with A already gone, which fails `analyse_geom`'s resize control because
// there is nothing left to compare B against.
//
// Holding the window for one dwell before the first phase turns that margin
// from "whatever the runner had left" into a dwell, on every platform. It moves
// nothing that is asserted: the sequence, the sizes and the positions are the
// same readings taken later, and no assertion here is about when A appears.
//
// The other three std probes have the same shape and have not shown the race.
// They are left alone until they do, which is the only evidence that would say
// what the right budget is for them.
function ready() {
    if (doc.body && win.neutrino) { win.setTimeout(phaseA, DWELL); }
    else { win.setTimeout(ready, 16); }
}

ready();
