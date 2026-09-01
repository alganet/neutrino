// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC

/*
 * The sample app published at https://alganet.github.io/neutrino/demo.cmd. It
 * opens a window and names the runtime it woke up on, which is the one thing a
 * screenshot cannot fake.
 *
 * Almost none of it is here any more. The window, its style and its markup are
 * the early shell -- style.css and body.html, included into the document by
 * assemble.sh -- so they are in the first paint and this script never draws
 * anything. What is left is the two facts no build can know: which engine
 * answered, and which transport it is speaking over.
 *
 * That is the whole point of the split. This used to write the page from
 * script, which meant every launch showed the launcher's own white document
 * first and the app a frame or more later, and it polled for a fifth of a
 * second before starting. Both were visible.
 *
 * ES5 only. This same source runs under JScript.NET, gjs, QtWebEngine and
 * WKWebView, and the oldest of them has neither arrow functions nor template
 * literals.
 *
 * An app may not carry a line reading `NeutrinoWebview.run();`: test/parse.sh
 * lifts the launcher's object out of a built .cmd with a sed range that ends
 * there, and the app is spliced inside that range. It used to end at the first
 * `    };` instead, which was a rule about this file's indentation; the anchor
 * now is a line nobody writes by accident.
 */
var win = eval("window");
var doc = eval("document");

function engineName() {
    var ua = win.navigator && win.navigator.userAgent ? win.navigator.userAgent : "";

    if (ua.indexOf("Edg") !== -1) return "WebView2";
    if (ua.indexOf("QtWebEngine") !== -1) return "QtWebEngine";
    if (ua.indexOf("Chrome") !== -1) return "Chromium";
    if (ua.indexOf("Safari") !== -1) return "WebKit";
    return "unknown";
}

function fill(id, text) {
    var el = doc.getElementById(id);
    if (el) el.textContent = text;
}

function closeWindow() {
    win.close();
}

function start() {
    fill("engine", engineName());
    fill("transport", win.neutrino.transport);
    doc.getElementById("close").onclick = closeWindow;
}

/*
 * Called, not scheduled.
 *
 * `window.neutrino` is in scope before an app's first statement on every lane,
 * and that is measured rather than assumed: test/neutrinostdgeom.js reads
 * `typeof window.neutrino` as its own first statement and reports it as `nt0`,
 * and both verifiers now fail a lane that answers anything but `yes`.
 * WebKitGTK under gjs, cjs and PyGObject, QtWebEngine, WKWebView and WebView2
 * all answer yes. So the fifth of a second this once polled for, and the frame
 * it polled for after that, were each waiting on something that had already
 * happened before the wait was armed.
 *
 * The markup is a second guarantee and a different one, and it still holds:
 * body.html and style.css are included into the document by assemble.sh and
 * this script sits after them, so the shell is parsed by the time the line below
 * runs. It is also why `document.readyState` can read `loading` at this point
 * on WebView2 -- the parser has not reached the end of the document, which says
 * nothing about the elements already above this script.
 */
start();
