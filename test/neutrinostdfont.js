// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// neutrinostdfont.js - what does CSS already know about the desktop's fonts?
//
// PROBE. The same question neutrinostdtheme.js asked about colour, asked about
// type, and it is worth asking separately because the early answer is the
// opposite one. Every non-deprecated <system-color> keyword turned out to be a
// constant on all four engines, which is what made `neutrino.theme` worth
// delivering. The CSS2 system *font* keywords -- caption, icon, menu,
// message-box, small-caption, status-bar -- are not constants on WebKitGTK:
// measured on this desk across two fresh launches with the desktop font moved
// between them,
//
//   desktop 'Ubuntu 10'             kw:menu = 13px / Ubuntu / 400
//   desktop 'DejaVu Serif Bold 17'  kw:menu = 22px / "DejaVu Serif" / 700
//
// family, size and weight all followed. So on that engine the keywords are the
// desktop's real font and a delivery would be restating them -- except for two
// things this file is here to pin down on the other three engines as well:
//
//   - they freeze at web-process start. The same flip under a *running* process
//     moved neither the loaded document nor a reloaded one. Launch-correct and
//     then permanently stale, which is one rung worse than the Qt
//     prefers-color-scheme finding, where a reload did catch up.
//   - all six were the same font. If that holds everywhere then CSS has one
//     system face and no notion of a monospace or title bar role, and the roles
//     are the part worth delivering whatever happens to the sizes.
//
// And the third question, which decides how the delivery is spelled: the CSS
// Fonts 4 generic families. `system-ui`, `ui-monospace`, `ui-serif`,
// `ui-sans-serif`, `ui-rounded` measured *unresolved* on WebKitGTK -- width
// identical to a family that does not exist, and `ui-monospace` was not even
// monospace. If that holds, there is no `font-family` keyword to put in a
// var() fallback the way `var(--neutrino-Canvas, Canvas)` puts one, and the
// asymmetry has to be written down rather than papered over.
//
// **What this file asserts now.** The round above was the one that reported;
// the delivery it decided is in, so the last two steps check it. verify-std.sh's
// analyse_font fails a lane where `neutrino.fonts` and the custom properties
// disagree, where an unset property does not reach the generic beside it, or --
// on the one engine that has an independent reading of the same desktop --
// where the launcher's size and the engine's differ by more than the pixel it
// truncates.
//
// The keyword and generic readings above are still reports and stay that way.
// They are the standing evidence for *why* the delivery is spelled with a
// separate `generic` field, and they would fail for a reason that is a fact
// about an engine rather than a defect in this launcher.
//
// ES5 only, because five web engines have to agree on it. Bare globals: this is
// the @else branch of the artifact, which jsc.exe never reads.
var win = window;
var doc = document;

var DWELL = 1500;

// Flat arrays of strings, never a multi-line object literal: parse.sh lifts
// NeutrinoWebview with a sed range that ends at four spaces and a closing
// brace, and an app carrying that line truncates the lift.
var KEYWORDS = ["caption", "icon", "menu", "message-box", "small-caption", "status-bar"];

var GENERICS = ["system-ui", "ui-sans-serif", "ui-serif", "ui-monospace", "ui-rounded",
                "sans-serif", "serif", "monospace", "cursive", "-apple-system"];

// The roles the launcher delivers, in the order fonts.js emits them.
var ROLES = ["ui", "document", "monospace", "titlebar", "small"];

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
    if (ua.indexOf("AppleWebKit") !== -1) { return "WebKit"; }
    return ua === "" ? "unknown-empty-ua"
        : "unknown[" + ua.replace(/[^A-Za-z0-9.\/ ]/g, "").substring(0, 48) + "]";
}

// One element, reused, off screen. Created rather than reaching for the body:
// the early shell is the app author's markup on every other build and a probe
// has no business assuming what is in it.
var probeEl = null;
function el() {
    if (!probeEl) {
        probeEl = doc.createElement("span");
        probeEl.style.position = "absolute";
        probeEl.style.left = "-9999px";
        probeEl.style.top = "-9999px";
        probeEl.style.whiteSpace = "pre";
        probeEl.textContent = "Handgloves 0123 IIll";
        doc.documentElement.appendChild(probeEl);
    }
    return probeEl;
}

// The sentinel, and it is the same lesson resolveColor learned in the theme
// probe: an engine that does not know a keyword does not throw and does not
// report an error. The assignment is ignored and the computed value is whatever
// the element already had -- which for a font is a plausible-looking font.
//
// So a shorthand no engine can resolve is assigned first, and every keyword
// that reads back as *that* is unsupported rather than measured. The sentinel
// is deliberately unlike any desktop's UI font -- 7px, italic, a family that
// does not exist -- because a sentinel a real answer could collide with is not
// a control.
var SENTINEL = "italic 7px NoSuchSentinelFamilyXYZ";
var SENTINEL_SIZE = "7px";

function resolveKeyword(kw) {
    var e = el();
    try {
        e.style.font = "";
        e.style.font = SENTINEL;
        e.style.font = kw;
        var cs = win.getComputedStyle(e);
        var size = String(cs.fontSize);
        var family = String(cs.fontFamily);
        var weight = String(cs.fontWeight);
        var style = String(cs.fontStyle);
        if (size === SENTINEL_SIZE && style === "italic") {
            return "UNSUP";
        }
        // Quotes and commas out of the family, so one keyword's reading cannot
        // be mistaken for two fields of the title line it lands in.
        family = family.replace(/["']/g, "").replace(/,\s*/g, "/");
        return size + "|" + family + "|" + weight + (style === "italic" ? "|italic" : "");
    } catch (_) {
        return "threw";
    } finally {
        try { e.style.font = ""; } catch (_) {}
    }
}

// Which generic families resolve, said by metric rather than by computed style.
//
// getComputedStyle is no use here and that is not a limitation of this file:
// font-family's computed value is the *specified* list, so an engine that
// ignores `system-ui` still reports `system-ui`. The only observable difference
// between a family that resolved and one that did not is what got drawn, so the
// width of a fixed string at a fixed size is the reading.
//
// Reported against ABSENT rather than in isolation. A generic whose width
// equals a family that certainly does not exist either did not resolve, or
// resolved to the same default face -- and those two are genuinely
// indistinguishable from in here, which is a fact about the measurement and is
// said in the log rather than guessed at.
var ABSENT = "NoSuchFontFamilyXYZ";

function widthOf(family) {
    var e = el();
    try {
        e.style.font = "";
        e.style.fontSize = "40px";
        e.style.fontFamily = "";
        e.style.fontFamily = family;
        return Math.round(e.getBoundingClientRect().width * 100) / 100;
    } catch (_) {
        return -1;
    }
}

function step1() {
    put("STD-FONT-CTL eng=" + engine());
    win.setTimeout(step2, DWELL);
}

// The six keywords, sizes and families. Split across two steps because six
// readings of `13px|Ubuntu|400` do not fit a title beside a prefix on the lane
// whose titles are also the transport.
function step2() {
    var out = "STD-FONT-KW-A";
    for (var i = 0; i < 3; i++) {
        out += " " + KEYWORDS[i] + "=" + resolveKeyword(KEYWORDS[i]);
    }
    put(out);
    win.setTimeout(step3, DWELL);
}

function step3() {
    var out = "STD-FONT-KW-B";
    for (var i = 3; i < KEYWORDS.length; i++) {
        out += " " + KEYWORDS[i] + "=" + resolveKeyword(KEYWORDS[i]);
    }
    // Whether the six are one font or six, which is the question that decides
    // whether CSS has any notion of a role at all. Said here rather than left
    // to whoever reads two title lines side by side.
    var first = resolveKeyword(KEYWORDS[0]);
    var same = 1;
    for (var j = 1; j < KEYWORDS.length; j++) {
        if (resolveKeyword(KEYWORDS[j]) === first) { same++; }
    }
    out += " identical=" + same + "/" + KEYWORDS.length;
    put(out);
    win.setTimeout(step4, DWELL);
}

function step4() {
    var absent = widthOf(ABSENT);
    var out = "STD-FONT-GEN absent=" + absent;
    for (var i = 0; i < GENERICS.length; i++) {
        var w = widthOf(GENERICS[i]);
        // `=` where it differs from the absent baseline and `~` where it does
        // not, so the shape of the answer survives being read quickly.
        out += " " + GENERICS[i] + (w === absent ? "~" : "=") + w;
    }
    put(out);
    win.setTimeout(step5, DWELL);
}

// The units, which decide what a delivered size has to be expressed in.
//
// A launcher reads points off every toolkit here except macOS, and CSS px is
// what a variable has to carry. `1in` says what the engine thinks an inch is --
// 96px by specification, and worth confirming rather than assuming on four
// engines -- and `10pt` says the conversion directly. devicePixelRatio is
// beside them because on the GTK lane it is where desktop text scaling *went*:
// text-scaling-factor 1.5 raised gtk-xft-dpi to 144 and dpr to 1.5 and left CSS
// px alone, so a lane that divided by the toolkit's DPI would have counted the
// same scaling twice.
function step5() {
    var out = "STD-FONT-UNIT";
    var d = doc.createElement("div");
    d.style.position = "absolute";
    d.style.left = "-9999px";
    doc.documentElement.appendChild(d);
    try {
        d.style.width = "1in";
        out += " 1in=" + Math.round(d.getBoundingClientRect().width * 100) / 100;
        d.style.width = "";
        d.style.fontSize = "10pt";
        out += " 10pt=" + win.getComputedStyle(d).fontSize;
        // The engine's own default size, which is what a `medium` computes to
        // and is the number a delivered size has to be compared against.
        //
        // Read through `medium` and not off the body, which was this file's
        // first spelling and was measuring the wrong thing: the early shell's
        // stylesheet is `html,body{font-size:2em}`, so the body reported 64px
        // -- 16 doubled at the root and doubled again by inheritance -- and the
        // reading was about neutrino's own shell rather than about the engine.
        // `medium` is an absolute keyword and inherits from nothing.
        d.style.fontSize = "medium";
        out += " medium=" + win.getComputedStyle(d).fontSize;
        d.style.fontSize = "";
        out += " dpr=" + win.devicePixelRatio;
        var root = win.getComputedStyle(doc.documentElement);
        out += " rootsize=" + root.fontSize +
            " rootfamily=" + String(root.fontFamily).replace(/["']/g, "").replace(/,\s*/g, "/");
    } catch (_) {
        out += " threw";
    }
    try { d.parentNode.removeChild(d); } catch (_) {}
    put(out);
    win.setTimeout(step6, DWELL);
}

// What the launcher delivered, which on this round is nothing. The line is here
// so that the round *after* this one -- the one that adds the delivery -- needs
// no new probe: the same app reports `fonts=null` now and a filled object then,
// and the two logs are directly comparable.
/*
 * What the launcher delivered, as an object.
 *
 * `fonts=null` is the null control and stays: a lane that read no toolkit
 * says so out loud rather than being filled in, exactly as `theme` is, and
 * every comparison in step7 is void on such a lane.
 */
function step6() {
    var out = "STD-FONT-NT-A";
    var fonts = fontsNow();
    if (!fonts) {
        out += " fonts=null";
    } else {
        out += " source=" + String(fonts.source);
        for (var i = 0; i < ROLES.length; i++) {
            var r = fonts[ROLES[i]];
            out += " " + ROLES[i] + "=" + (r
                ? (clean(r.family) === "" ? "-" : clean(r.family)) +
                  "/" + clean(r.generic) + "/" + clean(r.size) + "/" + clean(r.weight)
                : "absent");
        }
    }
    put(out);
    win.setTimeout(step7, DWELL);
}

// The object as the page has it, or null.
function fontsNow() {
    try { return (win.neutrino && win.neutrino.fonts) || null; } catch (_) { return null; }
}

// Quotes and commas out, so one role's reading cannot be mistaken for two
// fields of the title line it lands in.
function clean(v) {
    return String(v === undefined || v === null ? "" : v).replace(/["',\s]/g, "");
}

function cssVar(name) {
    try {
        return String(win.getComputedStyle(doc.documentElement)
            .getPropertyValue(name) || "").replace(/\s+/g, "");
    } catch (_) { return "threw"; }
}

/*
 * And the same delivery seen from the other side.
 *
 * Three readings, and each is a different kind of check.
 *
 * `match` is the direct twin of the palette probe's `match=7/7`: the object
 * the preload handed over against the custom properties the launcher wrote
 * into this document's stylesheet. Two mechanisms, one measurement, and an
 * app is entitled to either -- so a lane where they disagree is a window
 * whose two accounts of one desktop differ.
 *
 * `fallback` is the twin of `var(--neutrino-absent, Canvas)`: a property the
 * launcher never sets must reach the generic named beside it. It is what
 * says the documented idiom works on a lane that read nothing at all.
 *
 * `agree` is the one with no palette equivalent, and it is the strongest
 * check available here. On WebKitGTK the CSS2 `font: menu` keyword *is* the
 * desktop's font -- measured across two fresh launches, `Ubuntu 10` giving
 * 13px and `DejaVu Serif Bold 17` giving 22px -- so the engine has read the
 * same desktop the launcher read, independently, and the two numbers can be
 * compared. A unit bug, points delivered where pixels were wanted, is a
 * third off and nowhere near the tolerance. The engine truncates to whole
 * pixels where the launcher does not, which is the whole of the tolerance.
 */
function step7() {
    var out = "STD-FONT-NT-B";
    var fonts = fontsNow();
    if (!fonts) {
        out += " fonts=null match=0/0 fallback=notasked agree=notasked";
        put(out);
        paint();
        win.setTimeout(function () { put("STD-FONT-END"); }, DWELL);
        return;
    }

    var matched = 0, total = 0, missed = "";
    for (var i = 0; i < ROLES.length; i++) {
        var r = fonts[ROLES[i]];
        var want = [clean(r.stack), clean(r.size), clean(r.weight)];
        var got = [cssVar("--neutrino-font-" + ROLES[i]),
                   cssVar("--neutrino-font-size-" + ROLES[i]),
                   cssVar("--neutrino-font-weight-" + ROLES[i])];
        for (var j = 0; j < 3; j++) {
            total++;
            if (clean(got[j]) === want[j]) { matched++; }
            else if (missed === "") { missed = ROLES[i] + ":" + j; }
        }
    }
    out += " match=" + matched + "/" + total + (missed === "" ? "" : " first=" + missed);

    // An unset property must reach the generic beside it, which is what the
    // documented idiom rests on.
    var fb = "threw";
    try {
        var e = el();
        e.style.font = "";
        e.style.fontFamily = "var(--neutrino-font-nosuchrole, monospace)";
        fb = clean(win.getComputedStyle(e).fontFamily);
        e.style.fontFamily = "";
    } catch (_) {}
    out += " fallback=" + fb;

    // And the engine's own reading of the same desktop, where it has one.
    var kw = resolveKeyword("menu");
    var kwPx = (kw === "UNSUP" || kw === "threw") ? "" : String(kw).split("|")[0];
    var ntPx = clean(fonts.ui.size);
    if (kwPx === "" || ntPx === "") {
        out += " agree=notasked";
    } else {
        var a = parseFloat(kwPx), b = parseFloat(ntPx);
        var delta = Math.round(Math.abs(a - b) * 100) / 100;
        out += " agree=kw:" + a + "|nt:" + b + "|delta:" + delta;
    }

    put(out);
    paint();
    win.setTimeout(function () { put("STD-FONT-END"); }, DWELL);
}

// ------------------------------------------------------------------- the face
//
// The picture, for the same reason the theme probe has one: a screenshot of a
// blank page carrying the early shell's markup tells a reader nothing, and a
// font probe's whole subject is something a picture can show better than a
// title line can. Each row is rendered in the thing it names, so a lane where a
// keyword did not resolve is visibly the same face as its neighbour rather than
// a number the reader has to compare.
//
// Nothing here is read by anything that asserts.
function sampleRow(label, css, note) {
    return '<div style="display:flex;align-items:baseline;gap:10px;padding:3px 0;' +
        'border-bottom:1px solid rgba(128,128,128,.22)">' +
        '<div style="flex:0 0 128px;font:11px/1.4 monospace;opacity:.7">' + label + '</div>' +
        '<div style="flex:1 1 auto;' + css + '">Handgloves 0123 IIll</div>' +
        '<div style="flex:0 0 auto;font:10px/1.4 monospace;opacity:.55">' + note + '</div>' +
        '</div>';
}

function paint() {
    try {
        var body = doc.body;
        doc.documentElement.style.background = "var(--neutrino-Canvas, Canvas)";
        body.style.margin = "0";
        body.style.minHeight = "100vh";
        body.style.padding = "12px 14px";
        body.style.boxSizing = "border-box";
        body.style.background = "var(--neutrino-Canvas, Canvas)";
        body.style.color = "var(--neutrino-CanvasText, CanvasText)";
        body.style.font = "13px/1.5 sans-serif";

        var h = '<div style="font:600 15px/1.3 sans-serif;margin-bottom:10px">' +
            'FONT &middot; ' + engine() + '</div>';

        h += '<div style="font:11px/1.4 monospace;opacity:.6;margin:10px 0 4px">' +
            'the engine\'s own CSS2 system font keywords</div>';
        for (var i = 0; i < KEYWORDS.length; i++) {
            h += sampleRow(KEYWORDS[i], "font:" + KEYWORDS[i], resolveKeyword(KEYWORDS[i]));
        }

        h += '<div style="font:11px/1.4 monospace;opacity:.6;margin:12px 0 4px">' +
            'the CSS generic families, at 17px</div>';
        var absent = widthOf(ABSENT);
        for (var j = 0; j < GENERICS.length; j++) {
            var w = widthOf(GENERICS[j]);
            h += sampleRow(GENERICS[j], "font:17px " + GENERICS[j],
                (w === absent ? "= absent" : String(w)));
        }

        var fonts = fontsNow();
        h += '<div style="font:11px/1.4 monospace;opacity:.6;margin:12px 0 4px">' +
            'what the launcher delivered, as var(--neutrino-font-ROLE, generic)' +
            (fonts ? ' &mdash; source ' + clean(fonts.source) : ' &mdash; nothing; this lane read no toolkit') +
            '</div>';
        for (var k = 0; k < ROLES.length; k++) {
            var got = fonts && fonts[ROLES[k]];
            h += sampleRow(ROLES[k],
                "font-size:var(--neutrino-font-size-" + ROLES[k] + ",17px);" +
                "font-family:var(--neutrino-font-" + ROLES[k] + ",sans-serif);" +
                "font-weight:var(--neutrino-font-weight-" + ROLES[k] + ",400)",
                got ? (clean(got.stack) + " " + clean(got.size) + " " + clean(got.weight))
                    : "unset");
        }

        body.innerHTML = h;
    } catch (_) {
        // A face that throws must not take the probe with it: every reading
        // this app exists for has already left through the title by now.
    }
}

step1();
