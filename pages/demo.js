/*
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 *
 * The sample app published at https://alganet.github.io/neutrino/demo.cmd. It
 * opens a window and names the runtime it woke up on, which is the one thing a
 * screenshot cannot fake.
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

function closeWindow() {
    win.neutrino.window.close();
}

function start() {
    win.neutrino.window.setTitle("neutrino");
    win.neutrino.window.resize(520, 300);

    doc.body.innerHTML =
        '<style>' +
        'body{margin:0;display:flex;align-items:center;justify-content:center;' +
        'height:100vh;background:#12141a;color:#e6e8ee;text-align:center;' +
        'font:14px/1.6 -apple-system,Segoe UI,Cantarell,sans-serif}' +
        'h1{margin:0 0 8px;font-size:22px;font-weight:600}' +
        'p{margin:0 0 20px;color:#8b93a7}' +
        'b{color:#e6e8ee;font-weight:500}' +
        'button{font:inherit;padding:8px 18px;border:1px solid #2c3140;' +
        'border-radius:6px;background:#1b1f29;color:#e6e8ee;cursor:pointer}' +
        'button:hover{background:#232733}' +
        '</style>' +
        '<div>' +
        '<h1>Hello from neutrino</h1>' +
        '<p>One file, no install. Rendering in <b>' + engineName() + '</b><br>' +
        'over the <b>' + win.neutrino.transport + '</b> transport.</p>' +
        '<button id="close">Close</button>' +
        '</div>';

    doc.getElementById("close").onclick = closeWindow;
}

function waitForReady() {
    if (doc.body && win.neutrino) start();
    else win.setTimeout(waitForReady, 200);
}

waitForReady();
