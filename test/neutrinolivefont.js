// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// neutrinolivefont.js - does a *running* app notice the desktop's fonts moving?
//
// neutrinostdfont.js reads the set a launch was handed and asserts it. That is
// the right shape for what it asks -- whether the two deliveries agree, and
// whether the launcher and the engine read the same desktop -- and it is the
// wrong shape for this one: a launch reads its fonts once at startup, so a
// watcher that never fires produces a perfectly green launch.
//
// The palette lane has already paid for that gap once. On macOS both of its
// notification registrations passed `null` as the `object:` argument, JXA
// turned it into NSNull, and one of the two never fired and never raised. It
// was silent, and no suite in the tree could see it until neutrinolivetheme.js
// existed. This is that file's twin, and the hole it is aimed at is a
// different one.
//
// **Two roles are reported, and that is the whole design.** On GTK the `ui`
// role comes from `gtk-font-name` on GtkSettings and `monospace` comes from a
// GSettings key that GtkSettings has no equivalent for. They move
// independently, and they are watched by different signals:
// `notify::gtk-font-name` for the first, `changed::monospace-font-name` for
// the second. A probe printing `ui` alone would report `moved=no` for a
// monospace change it was handed and could not see -- and, worse, a build with
// the GSettings connections missing entirely would pass a one-flip run. That
// is exactly the shape of the accent defect neutrinolivetheme.js records, in a
// different lane.
//
// So fontflip.sh's live half flips twice and this file can tell the two apart.
//
// ES5 only, because five web engines have to agree on it. Bare globals: this is
// the @else branch of the artifact, which jsc.exe never reads.
var win = window;
var doc = document;

// How many sets this app has been handed, the first included. The counter is
// the point: `ui=DejaVu Serif` in a title is not evidence on its own -- the
// desktop may have been that when the app started -- and `n=2` with a
// different reading than `n=1` is.
var seen = 0;
var first = "";

// Quotes, commas and spaces out, so one role's reading cannot be mistaken for
// two fields of the title line it lands in.
function clean(v) {
    return String(v === undefined || v === null ? "" : v).replace(/["',\s]/g, "");
}

// One reading, flat.
//
// `src` first, because a lane that read no toolkit reports null and every
// comparison after it is void. Then `ui` and `mono`, for the reason the header
// gives: they are two roles, moved by two knobs, watched by two signals.
//
// The family, the size and the weight of each, because a desktop can move any
// one of the three on its own -- a font picker that changes only the size
// leaves the family byte-identical, and a watcher that fired would still be
// reported as `moved=no` by a probe that printed families alone.
function reading() {
    var f = null;
    try { f = win.neutrino && win.neutrino.fonts; } catch (_) {}
    if (!f) {
        return "src=null ui=null mono=null";
    }
    var one = function (role) {
        var r = f[role];
        if (!r) { return "absent"; }
        return (clean(r.family) === "" ? "-" : clean(r.family)) +
            "/" + clean(r.size) + "/" + clean(r.weight);
    };
    return "src=" + clean(f.source) + " ui=" + one("ui") + " mono=" + one("monospace");
}

function report() {
    seen = seen + 1;
    var r = reading();
    if (seen === 1) { first = r; }
    // `moved` is computed here rather than by the shell, for the reason
    // neutrinolivetheme.js gives: the shell polls a stream and may miss a
    // title, where the app saw every reading it was handed.
    doc.title = "STD-LIVEFONT n=" + seen +
        " moved=" + (r === first ? "no" : "yes") + " " + r;
}

// Painted in the fonts it is reporting, for the same reason the theme probe
// paints in its palette: a change nobody can see in the screenshot is a change
// a reader cannot check the title against. Here the picture is better evidence
// than it is there -- a family and a size are visible at a glance in a way a
// hex triple is not.
function paint() {
    try {
        var b = doc.body;
        b.style.margin = "0";
        b.style.minHeight = "100vh";
        b.style.padding = "16px 18px";
        b.style.boxSizing = "border-box";
        b.style.background = "var(--neutrino-Canvas, Canvas)";
        b.style.color = "var(--neutrino-CanvasText, CanvasText)";
        b.style.font = "13px/1.5 sans-serif";
        b.innerHTML = "<h2 style=\"margin:0 0 8px\">live fonts</h2>" +
            "<pre style=\"margin:0 0 12px;font:12px/1.5 monospace\">" +
            "sets handed to this page: " + seen + "\n" +
            "first:  " + first + "\n" +
            "latest: " + reading() + "</pre>" +
            "<div style=\"font-family:var(--neutrino-font-ui,sans-serif);" +
            "font-size:var(--neutrino-font-size-ui,17px);" +
            "font-weight:var(--neutrino-font-weight-ui,400)\">" +
            "ui &mdash; Handgloves 0123</div>" +
            "<div style=\"font-family:var(--neutrino-font-monospace,monospace);" +
            "font-size:var(--neutrino-font-size-monospace,17px)\">" +
            "monospace &mdash; Handgloves 0123</div>";
    } catch (_) {}
}

function update() {
    report();
    paint();
}

// The launcher's own event, and not a poll. `_fonts` sets
// window.neutrino.fonts and then dispatches this, so a handler may read the
// property directly. A poll would also work and would be the wrong instrument:
// it cannot tell "the watcher fired" from "the value changed under a page that
// happened to look again", and the watcher is the whole subject here.
try {
    win.addEventListener("neutrino:fontchange", function () { update(); });
} catch (_) {}

function ready() {
    if (win.neutrino && doc.body) { update(); }
    else { win.setTimeout(ready, 16); }
}
ready();
