// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC

/*
 * The sample app published at https://alganet.github.io/neutrino/demo.cmd. It
 * opens a window and drives it with the spellings a browser already has, so
 * that the page nobody has to install is also the page that demonstrates what
 * an app may do.
 *
 * Almost none of the window is here. The markup and its style are the early
 * shell -- body.html and style.css, included into the document by assemble.sh
 * -- so they are in the first paint and this script draws nothing. The palette
 * is not here either: every swatch and every button colour is one of the seven
 * custom properties the launcher writes from the desktop's own palette, so they
 * are right before this file runs and they follow a theme change with no script
 * involved. What is left is the readings no build can know, and the six calls.
 *
 * ES5 only. This same source runs under JScript.NET, gjs, QtWebEngine and
 * WKWebView, and the oldest of them has neither arrow functions nor template
 * literals. `eval("window")` and `eval("document")` for the same reason: the
 * file is compiled by jsc.exe on Windows, where neither global exists at
 * compile time.
 *
 * There is no wait at the bottom of this file and there used to be two. The API
 * is in scope before the first statement on every lane, and so is the document
 * -- the early shell is parsed before an app's script runs on all five, which
 * is what js/document.js's deferredPageScript is for on the one lane whose
 * engine does not offer that by itself. So this reads its own markup on the
 * first line and gets it.
 *
 * An app may not carry a line reading `NeutrinoWebview.run();`: test/parse.sh
 * lifts the launcher's object out of a built .cmd with a sed range that ends
 * there, and the app is spliced inside that range.
 */
var win = eval("window");
var doc = eval("document");

function el(id) {
    return doc.getElementById(id);
}

function fill(id, text) {
    var node = el(id);
    if (node) { node.textContent = text; }
}

/*
 * Which engine answered, off the user agent, because there is no other honest
 * way to ask and the launcher does not pretend to know. WKWebView carries no
 * product token at all, so it is the last of the WebKit tests rather than a
 * name to match.
 */
function engineName() {
    var ua = "";
    try { ua = String(win.navigator.userAgent || ""); } catch (_) { return "unknown"; }
    if (ua.indexOf("Edg") !== -1) { return "WebView2"; }
    if (ua.indexOf("QtWebEngine") !== -1) { return "QtWebEngine"; }
    if (ua.indexOf("Chrome") !== -1) { return "Chromium"; }
    if (ua.indexOf("AppleWebKit") !== -1) { return "WebKit"; }
    return "unknown";
}

/*
 * The window's content size, which is the quantity resizeTo sets and the only
 * geometry an app may read back: outerWidth is truthful on one engine of four
 * and screenX on a different one. innerWidth is correct everywhere.
 */
function showSize() {
    fill("size", win.innerWidth + " x " + win.innerHeight);
}

function showTheme() {
    var theme = win.neutrino.theme;
    if (!theme) {
        fill("scheme", "no palette on this lane");
        return;
    }
    fill("scheme", theme.scheme + " · " + theme.source + " · " +
        theme.colors.accent);
}

function on(id, handler) {
    var node = el(id);
    if (node) { node.onclick = handler; }
}

var renamed = 0;

/*
 * Six standard calls and nothing bespoke. Every one of these is the name the
 * web platform already has and your editor already knows; what neutrino does is
 * make them mean something in a window the user launched, where a browser
 * refuses them in silence.
 */
function wire() {
    on("bigger", function () { win.resizeBy(60, 40); });
    on("smaller", function () { win.resizeBy(-60, -40); });
    on("nudge", function () { win.moveBy(24, 24); });
    on("corner", function () { win.moveTo(0, 0); });
    on("rename", function () {
        renamed = renamed + 1;
        doc.title = "renamed " + renamed + " time" + (renamed === 1 ? "" : "s");
        fill("hint", "the window is called " + doc.title +
            ", because document.title names it");
    });
    on("source", function () {
        win.open("https://github.com/alganet/neutrino");
        fill("hint", "window.open sent that url to your browser, " +
            "which is a different program");
    });
    on("close", function () { win.close(); });
}

fill("engine", engineName());
fill("transport", win.neutrino.transport);
showSize();
showTheme();
wire();

/*
 * The window is resized by the desktop as well as by this page, so the readout
 * follows the window rather than the two buttons that move it.
 */
win.addEventListener("resize", showSize);

/*
 * And the desktop's palette, which is replaced rather than mutated when it
 * changes. The colours on screen need nothing from here -- the launcher rewrites
 * the custom properties on the same update -- so this only relabels the row that
 * says which palette it is.
 */
win.addEventListener("neutrino:themechange", showTheme);
