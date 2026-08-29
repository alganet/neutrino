/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 *
 * The sample app published at https://alganet.github.io/neutrino/demo.cmd. It
 * opens a window and names the runtime it woke up on, which is the one thing a
 * screenshot cannot fake.
 *
 * Almost none of it is here any more. The window, its style and its markup are
 * the early shell -- demo.css and demo.html, spliced into the document by
 * build.sh -- so they are in the first paint and this script never draws
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
 * Top-level closing braces are not indented four spaces here: test/parse.sh
 * lifts the NeutrinoWebview object out of a built .cmd with a sed range ending
 * at /^    };$/, and an app whose own code contains that line truncates it.
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
 * The markup is already there -- this script is injected at document end, so
 * the shell is parsed before the first statement above runs. What may not be
 * there yet is the API, which each engine registers on its own schedule.
 *
 * So the wait is for `neutrino` and not for `document.body`, and it is a frame
 * rather than the fifth of a second it used to be. Nothing on screen depends on
 * it now: the page is painted and correct while this is still waiting, and all
 * that arrives late is two words and a click handler.
 */
function waitForReady() {
    if (win.neutrino) start();
    else win.setTimeout(waitForReady, 16);
}

waitForReady();
