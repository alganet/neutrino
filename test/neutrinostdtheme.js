// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// neutrinostdtheme.js - is `neutrino.theme` redundant with CSS?
//
// The API hands a page seven colours and a scheme, read off the running
// toolkit. CSS has a name for all of that already: `prefers-color-scheme` for
// the scheme, and the non-deprecated <system-color> keywords for the palette --
// Canvas, CanvasText, ButtonFace, ButtonText, ButtonBorder, AccentColor,
// AccentColorText, and the selection pair beside them. If the four engines
// resolve those to the *desktop's* values, the whole object is a bespoke
// restatement of two web platform features and can go. If they resolve them to
// values of their own, the measurement is the thing worth keeping and only the
// delivery is redundant.
//
// This file asks. It does not answer: one launch cannot tell a hardcoded value
// from a desktop value that happens to look like one. That takes two launches
// with the palette flipped between them, which is the round after this, and the
// differential is the answer. What this round is for is the shape of the
// readings and the two controls underneath them.
//
// The first control is the one neutrinotest.js has always carried: a lane whose
// toolkit could not be read reports `theme === null`, and every comparison here
// is meaningless on it. That is a reading, not a failure -- but it has to be
// said out loud, because a null palette compared against a hardcoded CSS colour
// produces a difference that looks exactly like a finding.
//
// The second is the one this file could not do without. An engine that does not
// know a colour keyword does not throw and does not report an error: the
// assignment is ignored and the computed value is whatever the element already
// had -- which is a plausible-looking colour. So a keyword no engine can know
// is assigned first, and every system colour that reads back the same as that
// one is unsupported rather than measured. Without it this file would report
// thirteen confident values on an engine that implements none of them.
//
// ES5 only, `eval("window")` and `eval("document")`: jsc.exe compiles this.
var win = eval("window");
var doc = eval("document");

var DWELL = 1500;

// Flat arrays of strings, never a multi-line object literal: parse.sh lifts
// NeutrinoWebview with a sed range that ends at four spaces and a closing
// brace, and an app carrying that line truncates the lift.
var NT_KEYS = ["background", "foreground", "base", "text", "accent", "accentText", "border"];

// The non-deprecated <system-color> keywords, in the order the mapping table
// pairs them with the seven above -- Canvas/CanvasText for the content surface,
// ButtonFace/ButtonText/ButtonBorder for the window chrome, and then both
// spellings of the accent, because three of the four lanes read the *selection*
// colour where only macOS reads the OS accent. Which name this API should use
// is decided by which of these two pairs the desktop value matches.
var CSS_COLORS = ["Canvas", "CanvasText", "ButtonFace", "ButtonText", "ButtonBorder",
                  "AccentColor", "AccentColorText", "Highlight", "HighlightText",
                  "SelectedItem", "SelectedItemText", "Field", "FieldText",
                  "GrayText", "LinkText"];

// A keyword no engine can resolve. Everything below is compared against what
// this reads back; a match means "not supported", not a colour.
//
// It is read against SENTINEL and not against whatever the element inherited,
// and that is a correction this file already needed once. An unresolvable
// keyword leaves the declaration alone, so the computed value is the previous
// one -- and the previous one was black, which is exactly what a light
// desktop's CanvasText legitimately is. Measured: the first draft reported
// CanvasText=UNSUP on a lane, and could not have distinguished that from an
// engine answering correctly. A base colour no palette will ever contain
// removes the collision instead of narrowing it.
var BOGUS = "nosuchsystemcolour";
var SENTINEL = "rgb(1, 2, 3)";
var SENTINEL_HEX = "010203";

function put(s) {
    var t = String(s);
    if (t.length > 1000) {
        t = "STD-OVER len=" + t.length + " " + t.substring(0, 900);
    }
    doc.title = t;
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

// rgb(r, g, b) or rgba(...) to six hex digits, so a reading is comparable
// against neutrino.theme's own spelling without the reader doing arithmetic.
function toHex(css) {
    var m = String(css).match(/(\d+)[,\s]+(\d+)[,\s]+(\d+)/);
    if (!m) { return String(css).replace(/[^0-9a-zA-Z]/g, "").substring(0, 12); }
    var out = "";
    for (var i = 1; i <= 3; i++) {
        var h = Number(m[i]).toString(16);
        out += (h.length < 2 ? "0" : "") + h;
    }
    return out;
}

// One element, reused, off-screen. Created rather than reaching for the body:
// the early shell is the app author's markup on every other build and a probe
// has no business assuming what is in it.
var probeEl = null;
function resolveColor(keyword) {
    try {
        if (!probeEl) {
            probeEl = doc.createElement("span");
            probeEl.style.position = "absolute";
            probeEl.style.left = "-9999px";
            doc.documentElement.appendChild(probeEl);
        }
        probeEl.style.color = SENTINEL;
        probeEl.style.color = keyword;
        var got = toHex(win.getComputedStyle(probeEl).color);
        // Said here rather than by comparing two readings at the call site, so
        // a colour that genuinely is the sentinel cannot be mistaken for a
        // refusal by one caller and not by another.
        return (got === SENTINEL_HEX) ? "UNSUP" : got;
    } catch (_) {
        return "threw";
    }
}

// The width of one fixed string in three families. system-ui does not resolve
// through getComputedStyle -- the computed value is the specified list -- so
// the only answer available is metric. Reported, never asserted: it says the
// three differ, not which font any of them is.
function fontWidths() {
    var out = "";
    var fams = ["system-ui", "sans-serif", "NoSuchFontFamilyHere"];
    var names = ["sysui", "sans", "absent"];
    try {
        var el = doc.createElement("span");
        el.style.position = "absolute";
        el.style.left = "-9999px";
        el.style.fontSize = "40px";
        el.textContent = "Handgloves 0123";
        doc.documentElement.appendChild(el);
        for (var i = 0; i < fams.length; i++) {
            el.style.fontFamily = fams[i];
            out += " " + names[i] + "=" + Math.round(el.getBoundingClientRect().width);
        }
        el.parentNode.removeChild(el);
    } catch (_) { out = " sysui=threw sans=threw absent=threw"; }
    return out;
}

function step1() {
    put("STD-THEME-CTL eng=" + engine());
    win.setTimeout(step2, DWELL);
}

// What the launcher read off the toolkit, and what the media query says beside
// it. The scheme is derived from the luminance of the background rather than
// from a toolkit flag -- measured, because on one desktop the flag reads light
// while the window is dark grey -- so a media query that disagrees here is the
// engine repeating the flag this file already refuses to trust.
function step2() {
    var out = "STD-THEME-A-SELF";
    var mq = "unsupported";
    try {
        if (win.matchMedia) {
            if (win.matchMedia("(prefers-color-scheme: dark)").matches) { mq = "dark"; }
            else if (win.matchMedia("(prefers-color-scheme: light)").matches) { mq = "light"; }
            else { mq = "none"; }
        }
    } catch (_) { mq = "threw"; }
    out += " mq=" + mq;

    var theme = null;
    try { theme = win.neutrino.theme; } catch (_) {}
    if (!theme) {
        out += " nsrc=null nscheme=null";
    } else {
        out += " nsrc=" + theme.source + " nscheme=" + theme.scheme;
        for (var i = 0; i < NT_KEYS.length; i++) {
            var v = "?";
            try { v = String(theme.colors[NT_KEYS[i]]).replace("#", ""); } catch (_) {}
            out += " n:" + NT_KEYS[i] + "=" + v;
        }
    }
    put(out);
    win.setTimeout(step3, DWELL);
}

function step3() {
    // The control, and it has to read UNSUP or nothing below means anything:
    // an engine that resolved this one is an engine resolving anything, and
    // every UNSUP after it would be the instrument rather than the engine.
    var out = "STD-THEME-B-SELF control=" + resolveColor(BOGUS);
    for (var i = 0; i < CSS_COLORS.length; i++) {
        out += " " + CSS_COLORS[i] + "=" + resolveColor(CSS_COLORS[i]);
    }
    put(out);
    win.setTimeout(step4, DWELL);
}

// Whether the delivery this design proposes is even available. Custom
// properties are written through CSSOM rather than through a <style> element on
// purpose: the offline tier's document carries `default-src 'none'`, and a
// property write is not governed by style-src -- which is a claim about four
// engines and two tiers, so it is measured here rather than designed around.
function step4() {
    var set = "threw";
    var read = "threw";
    try {
        doc.documentElement.style.setProperty("--neutrino-Canvas", "#123456");
        set = "ok";
        read = String(win.getComputedStyle(doc.documentElement)
            .getPropertyValue("--neutrino-Canvas")).replace(/[^0-9a-fA-F]/g, "");
    } catch (_) {}
    var pol = "NONE";
    try {
        var m = doc.querySelector('meta[http-equiv="Content-Security-Policy"]');
        var c = m ? String(m.getAttribute("content") || "") : "";
        if (c.indexOf("default-src 'none'") === 0) { pol = "OFFLINE"; }
        else if (c.indexOf("script-src") === 0) { pol = "DEFAULT"; }
        else if (c) { pol = "OTHER"; }
    } catch (_) { pol = "UNREADABLE"; }
    put("STD-THEME-P-SELF setprop=" + set + " readback=" + read + " pol=" + pol);
    win.setTimeout(step5, DWELL);
}

function step5() {
    put("STD-THEME-F-SELF" + fontWidths());
    win.setTimeout(step6, DWELL);
}

function step6() { put("STD-THEME-END"); }

function ready() {
    // `doc.body` and not `doc.documentElement`: the parser inserts `<html>`
    // before `<head>`, so documentElement is true inside the window where a
    // `document.title` write -- which is how this suite reports -- does nothing
    // at all. Waiting for the body is waiting for `</head>` to have been passed.
    if (win.neutrino && doc.body) { step1(); }
    else { win.setTimeout(ready, 16); }
}

ready();
