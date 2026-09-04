// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// neutrinolivetheme.js - does a *running* app notice the desktop flipping?
//
// neutrinostdtheme.js reads the palette a launch was handed and reports it, and
// themeflip.sh runs it twice with the desktop flipped in between. Two launches
// is the right shape for the question that file asks -- whether a colour came
// from the desktop or from the engine -- and it is the wrong shape for a
// different one, which nothing here was asking: whether the theme *watcher*
// works. Every driver has one. None of them is on the path of a launch that
// starts after the flip, because the palette is read once at startup either
// way, so a watcher that never fires produces two green halves.
//
// It did. On macOS both notification registrations passed `null` as the
// `object:` argument, JXA turned that into NSNull rather than nil, and:
//
//   - NSDistributedNotificationCenter sent -length to it and raised
//     "-[NSNull length]: unrecognized selector", which the driver caught and
//     turned into a note
//   - NSNotificationCenter took it quietly and used it as the filter it is: an
//     observer registered for object NSNull matches notifications posted with
//     object NSNull, and nothing posts one. It never raised and never fired.
//
// The second is the one that matters here. It was silent, it was the only
// half that could have been silent, and no suite in the tree could see it.
//
// So this app holds still and waits. It reports the palette it started with,
// then reports again on every `neutrino:themechange` the launcher delivers,
// with a counter in front so the reader can tell a second reading from a first
// that never moved. What flips the desktop underneath it is themeflip.sh's
// live half; what this file contributes is a window whose title answers.
//
// ES5 only, `eval("window")` and `eval("document")`: jsc.exe compiles this.
var win = eval("window");
var doc = eval("document");

// How many themes this app has been handed, the first one included. The whole
// point of the counter: `scheme=dark` in a title is not evidence on its own --
// the desktop may have been dark when the app started -- and `n=2` with a
// different scheme than `n=1` is.
var seen = 0;
var first = "";

// One reading, flat. Two things are named that the scheme alone does not
// settle: `src`, the toolkit the launcher read the palette off, because a lane
// that read nothing reports scheme=null and every comparison is void; and
// `canvas`, the background colour itself, because a scheme is derived from a
// palette and a palette that moved without changing the derived word is still
// a watcher that fired.
function reading() {
    var t = null;
    try { t = win.neutrino && win.neutrino.theme; } catch (_) {}
    if (!t) {
        return "src=null scheme=null canvas=null";
    }
    var canvas = "?";
    try { canvas = String(t.colors.background).replace("#", ""); } catch (_) {}
    return "src=" + t.source + " scheme=" + t.scheme + " canvas=" + canvas;
}

function report() {
    seen = seen + 1;
    var r = reading();
    if (seen === 1) { first = r; }
    // `moved` is computed here rather than by the shell, because the shell
    // would have to parse two titles out of a stream it polls and may miss one.
    // The app saw every reading it was given and can say whether the latest
    // differs from the first without anything being sampled.
    doc.title = "STD-LIVE n=" + seen +
        " moved=" + (r === first ? "no" : "yes") + " " + r;
}

// Painted, for the same reason the theme probe paints: a flip nobody can see in
// the screenshot is a flip a reader cannot check the title against.
function paint() {
    try {
        doc.documentElement.style.background = "var(--neutrino-Canvas, Canvas)";
        var b = doc.body;
        b.style.margin = "0";
        b.style.minHeight = "100vh";
        b.style.padding = "16px 18px";
        b.style.boxSizing = "border-box";
        b.style.background = "var(--neutrino-Canvas, Canvas)";
        b.style.color = "var(--neutrino-CanvasText, CanvasText)";
        b.style.font = "13px/1.5 system-ui, sans-serif";
        b.innerHTML = "<h2 style=\"margin:0 0 8px\">live theme</h2>" +
            "<pre style=\"margin:0;font:12px/1.5 monospace\">" +
            "themes handed to this page: " + seen + "\n" +
            "first:  " + first + "\n" +
            "latest: " + reading() + "</pre>";
    } catch (_) {}
}

function update() {
    report();
    paint();
}

// The launcher's own event, and not a poll. `_theme` sets window.neutrino.theme
// and then dispatches this, so a handler may read the property directly -- see
// the comment beside _theme in message.js. A poll would also work and would be
// the wrong instrument: it cannot tell "the watcher fired" from "the value
// changed under a page that happened to look again".
try {
    win.addEventListener("neutrino:themechange", function () { update(); });
} catch (_) {}

function ready() {
    if (win.neutrino && doc.body) { update(); }
    else { win.setTimeout(ready, 16); }
}
ready();
