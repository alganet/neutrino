// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// neutrinostdwin.js - can the standard window verbs be made true here?
//
// `neutrino.window.resize(w,h)` has a spelling every browser already has, and
// so do move, close and openExternal. Whether an app can be written against
// those instead turns on three questions this file asks in order.
//
// Does the engine ship them, and do they do anything? A browser refuses
// resizeTo, moveTo and close on a window a script did not open, and four
// embedders may each have decided that differently -- so each is called and the
// harness watches whether the native window moved.
//
// Can the launcher take them over if it does not? That is a property
// descriptor: on Window these are ordinary configurable properties by spec, but
// four engines say what they say, and a defineProperty that neither throws nor
// takes effect looks exactly like one that worked.
//
// And does the launcher's own API still work while all that is being asked?
// That is the control, and it is deliberately *after* the four native attempts
// rather than before them. Every "the native call did nothing" reading here is
// equally explained by a window that stopped responding, and the only thing
// that separates those is a call known to work, made through the same
// instrument, in the same run, after the ones in doubt.
//
// Two orderings are load-bearing and neither is arbitrary. The override phase
// comes after every native call, because overriding resizeTo and then calling
// it measures the override rather than the engine. And close comes last,
// because it destroys the window every reading is reported through -- if it
// works there is nothing left to report from, which is itself the answer.
//
// ES5 only, `eval("window")` and `eval("document")`: jsc.exe compiles this.
var win = eval("window");
var doc = eval("document");
/*
 * And Object, through eval for the same reason the other two are.
 *
 * README.md says to reach window and document this way because jsc.exe
 * compiles this file and neither exists at compile time. The rule is wider than
 * the two names it gives: JScript.NET is ES3-era and typed, so `Object` is a
 * type it knows, and `Object.getOwnPropertyDescriptor` is a member of it that
 * does not exist -- which a typed compiler resolves and refuses rather than
 * leaving to fail at run time inside the try that is waiting for it.
 *
 * Measured as an absence: this is the only probe in this branch that reaches
 * ES5 statics, and it is the only one whose window never appeared on Windows,
 * with the build green, no app folder made and nothing written to any log. The
 * fix is reasoned from that and from the file's own rule; the round after this
 * is what says whether it was right.
 */
var OBJ = eval("Object");

var DWELL = 1500;
// A frame for the toolkit to act before the page is asked what it thinks
// happened. Not a settling budget -- the harness records continuously.
var SETTLE = 250;

// Flat arrays of strings. A multi-line object literal closing at four spaces
// truncates parse.sh's lift of NeutrinoWebview and reports as a syntax error
// against a line number in a temporary file.
var PROPS = ["outerWidth", "outerHeight", "innerWidth", "innerHeight",
             "screenX", "screenY", "resizeTo", "resizeBy", "moveTo", "moveBy",
             "close", "open"];
var SHORT = ["ow", "oh", "iw", "ih", "sx", "sy", "rt", "rz", "mt", "mv", "cl", "op"];

// Overridden and restored, one at a time. `close` is not in here on purpose:
// a failed restore would leave the last phase calling a stub, and "close did
// nothing" and "close was replaced" are the same empty reading. Its descriptor
// in the phase above already says whether an override is possible, which is
// the question -- performing one is what the fix will do and what its own
// suite will assert.
var OVERRIDABLE = ["outerWidth", "screenX", "resizeTo", "moveTo", "open"];
// Carried beside it rather than looked up. Array.prototype.indexOf is ES5 and
// this file is also compiled by jsc.exe, and a second array costs one line
// against a guard nobody can check from here.
var OVERRIDABLE_SHORT = ["ow", "sx", "rt", "mt", "op"];

function put(s) {
    var t = String(s);
    if (t.length > 1000) {
        t = "STD-OVER len=" + t.length + " " + t.substring(0, 900);
    }
    try { win.neutrino.window.setTitle(t); } catch (_) {}
}

function engine() {
    var ua = "";
    try { ua = String(win.navigator.userAgent || ""); } catch (_) { return "unknown"; }
    if (ua.indexOf("Edg") !== -1) { return "WebView2"; }
    if (ua.indexOf("QtWebEngine") !== -1) { return "QtWebEngine"; }
    if (ua.indexOf("Chrome") !== -1) { return "Chromium"; }
    if (ua.indexOf("Safari") !== -1) { return "WebKit"; }
    return "unknown";
}

function num(v) {
    var n = Number(v);
    if (!isFinite(n)) { return "NaN"; }
    return String(Math.round(n));
}

// The page's half of every pair below. Short, because twelve titles carry it.
function geom() {
    var out = "";
    try { out += " ow=" + num(win.outerWidth) + " oh=" + num(win.outerHeight); } catch (_) { out += " ow=threw oh=threw"; }
    try { out += " iw=" + num(win.innerWidth) + " ih=" + num(win.innerHeight); } catch (_) { out += " iw=threw ih=threw"; }
    try { out += " sx=" + num(win.screenX) + " sy=" + num(win.screenY); } catch (_) { out += " sx=threw sy=threw"; }
    return out;
}

// Whether a call happened, not whether it worked. What it did is the harness's
// half, and conflating the two is how a no-op gets reported as a refusal.
function attempt(fn) {
    try {
        fn();
        return "ok";
    } catch (e) {
        return "threw:" + String(e && e.name ? e.name : e).substring(0, 24);
    }
}

// ------------------------------------------------------------------- phases

function pEXIST() {
    var out = "STD-WIN-EXIST-SELF eng=" + engine();
    for (var i = 0; i < PROPS.length; i++) {
        var t = "absent";
        try { t = typeof win[PROPS[i]]; } catch (_) { t = "threw"; }
        out += " " + SHORT[i] + "=" + t;
    }
    var fs = "absent";
    try { fs = typeof (doc.documentElement && doc.documentElement.requestFullscreen); } catch (_) {}
    var xfs = "absent";
    try { xfs = typeof doc.exitFullscreen; } catch (_) {}
    put(out + " rfs=" + fs + " xfs=" + xfs);
    win.setTimeout(pDESC, DWELL);
}

// w/c are the two flags an override needs; o says where the property lives,
// because a value found only on the prototype is overridden by shadowing it
// and one found on the instance is overridden in place.
function describe(name) {
    var d = null;
    var owner = "N";
    try {
        d = OBJ.getOwnPropertyDescriptor(win, name);
        if (d) { owner = "S"; }
        else {
            var proto = OBJ.getPrototypeOf(win);
            if (proto) {
                d = OBJ.getOwnPropertyDescriptor(proto, name);
                if (d) { owner = "P"; }
            }
        }
    } catch (_) { return "threw"; }
    if (!d) { return "none"; }
    // Bracketed, not dotted. `get` and `set` are how JScript.NET spells a
    // property accessor, and webview.cmd already quotes "close" for the same
    // family of reasons -- jsc is stricter than the other four engines about
    // names that look like they might mean something.
    return "w" + (d["writable"] || d["set"] ? 1 : 0) + "c" + (d["configurable"] ? 1 : 0) +
        "g" + (d["get"] ? 1 : 0) + "o" + owner;
}

function pDESC() {
    var out = "STD-WIN-DESC-SELF";
    for (var i = 0; i < PROPS.length; i++) {
        out += " " + SHORT[i] + "=" + describe(PROPS[i]);
    }
    // Two controls, and without them "configurable:false" is the reader rather
    // than the engine. A property this file defines itself must come back
    // writable and configurable; `window`, which the spec makes unforgeable,
    // must come back neither. An engine that answers the same for both is one
    // whose descriptors say nothing, and every reading above is void.
    try { win.__ntProbeCtl = 1; } catch (_) {}
    put(out + " CTLown=" + describe("__ntProbeCtl") + " CTLforged=" + describe("window"));
    win.setTimeout(pRT, DWELL);
}

function pRT() {
    var r = attempt(function () { win.resizeTo(640, 480); });
    win.setTimeout(function () {
        put("STD-WIN-RT-PAIR req=640x480 call=" + r + geom());
        win.setTimeout(pRZ, DWELL);
    }, SETTLE);
}

function pRZ() {
    var r = attempt(function () { win.resizeBy(40, 40); });
    win.setTimeout(function () {
        put("STD-WIN-RZ-PAIR req=+40+40 call=" + r + geom());
        win.setTimeout(pMT, DWELL);
    }, SETTLE);
}

function pMT() {
    var r = attempt(function () { win.moveTo(120, 90); });
    win.setTimeout(function () {
        put("STD-WIN-MT-PAIR req=120,90 call=" + r + geom());
        win.setTimeout(pMV, DWELL);
    }, SETTLE);
}

function pMV() {
    var r = attempt(function () { win.moveBy(30, 30); });
    win.setTimeout(function () {
        put("STD-WIN-MV-PAIR req=+30+30 call=" + r + geom());
        win.setTimeout(pCTL, DWELL);
    }, SETTLE);
}

// The positive control, after the four in doubt and through the same
// instrument. A run where this one does not move the window has measured
// nothing above it, and says so instead of reporting four refusals.
function pCTL() {
    var a = attempt(function () { win.neutrino.window.resize(700, 520); });
    var b = attempt(function () { win.neutrino.window.move(60, 40); });
    win.setTimeout(function () {
        put("STD-WIN-CTL-PAIR req=700x520@60,40 resize=" + a + " move=" + b + geom());
        win.setTimeout(pOPEN, DWELL);
    }, SETTLE);
}

// about:blank, never a real url. `openExternal` on this platform ends at the
// desktop's URI handler and would launch a browser into the middle of a lane;
// what is being asked here is only what the engine does with the call.
//
// Marked -SELF: whether a *second native window* appeared is the outside half
// and this harness does not count windows yet. That is the round after this,
// and saying so is cheaper than a pair with one half missing.
function pOPEN() {
    var ret = "threw";
    var before = "";
    try { before = String(win.location.href); } catch (_) {}
    try {
        var w = win.open("about:blank", "_blank");
        ret = (w === null) ? "null" : (w === undefined ? "undefined" : typeof w);
    } catch (e) { ret = "threw:" + String(e && e.name ? e.name : e).substring(0, 24); }
    var after = "";
    try { after = String(win.location.href); } catch (_) {}
    put("STD-WIN-OPEN-SELF ret=" + ret + " href=" + (before === after ? "same" : "CHANGED"));
    win.setTimeout(pREGION, DWELL);
}

function pREGION() {
    var got = "threw";
    try {
        var el = doc.createElement("div");
        el.style.position = "absolute";
        el.style.left = "-9999px";
        el.style.setProperty("-webkit-app-region", "drag");
        doc.documentElement.appendChild(el);
        got = String(win.getComputedStyle(el).getPropertyValue("-webkit-app-region") || "");
        if (!got) { got = "empty"; }
        el.parentNode.removeChild(el);
    } catch (_) {}
    put("STD-WIN-APPREGION-SELF computed=" + got);
    win.setTimeout(pFS, DWELL);
}

// Without a user gesture, which is the case an app that wants to start
// fullscreen is in. A refusal here is expected on every engine and is not the
// finding; what the finding would be is a lane where it succeeds, or one where
// the promise never settles at all. The gesture case needs the harness to
// synthesize a click and belongs in the round after this.
function pFS() {
    var settled = "pending";
    var call = attempt(function () {
        var p = doc.documentElement.requestFullscreen();
        if (p && p.then) {
            p.then(function () { settled = "resolved"; },
                   function (e) { settled = "rejected:" + String(e && e.name ? e.name : e).substring(0, 20); });
        } else {
            settled = "novalue";
        }
    });
    win.setTimeout(function () {
        var el = "none";
        try { el = doc.fullscreenElement ? "set" : "none"; } catch (_) { el = "threw"; }
        var act = "unknown";
        try { act = win.navigator.userActivation ? String(win.navigator.userActivation.isActive) : "absent"; } catch (_) {}
        put("STD-WIN-FS1-PAIR nogesture call=" + call + " settled=" + settled +
            " fsel=" + el + " activation=" + act + geom());
        try { if (doc.fullscreenElement && doc.exitFullscreen) { doc.exitFullscreen(); } } catch (_) {}
        win.setTimeout(pOVR, DWELL);
    }, 900);
}

// After every native call above, or this phase would be measuring itself.
// Each property is restored from its own saved descriptor immediately, and the
// restore is reported: a reading taken after a failed restore is a reading
// about a window this file broke.
function pOVR() {
    var out = "STD-WIN-OVR-SELF";
    for (var i = 0; i < OVERRIDABLE.length; i++) {
        var name = OVERRIDABLE[i];
        // Not `short`. That is a CLR type alias and a JScript.NET reserved
        // word, so the declaration is valid JavaScript in four engines and a
        // compile error in the one that compiles this file -- which shows up
        // as a Windows lane whose app never opens a window and says nothing
        // else. parse.sh refuses the whole family now.
        var abbr = OVERRIDABLE_SHORT[i];
        var mark = {};
        var saved = null;
        var verdict = "threw";
        try {
            saved = OBJ.getOwnPropertyDescriptor(win, name);
            OBJ.defineProperty(win, name, { value: mark, writable: true, configurable: true });
            // Neither throwing nor taking effect is the outcome that looks like
            // success and is not, so the read-back is the verdict and the
            // absence of an exception is not.
            verdict = (win[name] === mark) ? "ok" : "silent";
        } catch (e) {
            verdict = "threw:" + String(e && e.name ? e.name : e).substring(0, 20);
        }
        var restored = "n/a";
        try {
            if (saved) { OBJ.defineProperty(win, name, saved); restored = "yes"; }
            else { delete win[name]; restored = (win[name] === mark) ? "NO" : "yes"; }
        } catch (_) { restored = "NO"; }
        out += " " + abbr + "=" + verdict + "/" + restored;
    }
    put(out);
    win.setTimeout(pCLOSE, DWELL);
}

// Last, because it destroys the window every reading above went out through.
// If it works there is nothing left to report from, and that absence is the
// reading -- the harness records the window going away.
function pCLOSE() {
    put("STD-WIN-CLOSE-PAIR about-to-call");
    win.setTimeout(function () {
        var r = attempt(function () { win.close(); });
        win.setTimeout(function () {
            var closed = "?";
            try { closed = String(win.closed); } catch (_) {}
            put("STD-WIN-END call=" + r + " closed=" + closed);
        }, 1200);
    }, DWELL);
}

function ready() {
    if (win.neutrino && doc.documentElement) { pEXIST(); }
    else { win.setTimeout(ready, 16); }
}

ready();
