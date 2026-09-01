// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// neutrinooffline.js - an app that tries to reach the network nine ways.
//
// `build.sh --tier=offline` says it denies the page network access. The whole
// mechanism is one meta tag in the extracted document, and nothing in this
// repository has ever built that tier, let alone run it: the only assertion it
// has is a string comparison in parse.sh. Whether a document carrying
// `default-src 'none'` actually stops the app's own code from reaching a host
// is a per-engine answer, and it is a live question rather than a formality --
// the comment above the content policy says injected script is "exempt from the
// policy the document carries", which is why the app runs at all under
// `script-src` with no sources. If the exemption extends to what that script
// then *loads*, the offline tier denies nothing at all.
//
// So this file is the app's page script, engine-injected exactly like any
// app's, and it asks that question nine times. Then it asks a tenth and an
// eleventh, which no content policy has an opinion about at all -- see
// escape_() below.
//
// The instrument is the target server's request log, not the page. What left
// the machine is the finding; what the page thinks happened is a diagnostic
// beside it, and the two disagree on purpose -- a cross-origin fetch from a
// null-origin document is refused by CORS *after* the request has gone, which
// reads as an error in here and as a hit over there. Exfiltration is the second
// reading, so the second reading is the one that counts.
//
// Two of the nine are constants rather than variables, and they are the control
// that says the engine honours the meta tag at all: `script-src` names no
// source and `frame-src` is 'none' in *both* policies, so `script` and `frame`
// must be absent from the log even in the default tier. An engine where those
// two arrive is an engine ignoring the document's policy, and every "blocked"
// reading under the offline tier on that engine would mean nothing.
var win = eval("window");
var doc = eval("document");

// The port test/verify-offline.sh and test/verify-offline.ps1 serve test/ on.
// Not a configurable: the harness and this file have to agree on one number,
// and there is no environment in a page to read one from.
var PORT = 8096;
var BASE = "http://127.0.0.1:" + PORT + "/";

var ORDER = ["fetch", "xhr", "img", "css", "script", "frame", "beacon", "sse", "ws"];
var marks = {};

// First writer wins. An `img` that fires error after load, or a WebSocket that
// opens and then closes, would otherwise overwrite the answer with the tail of
// its own lifecycle instead of with what the policy decided.
function mark(k, v) {
    if (marks[k] === "PEND") marks[k] = v;
}

function url(file, k) {
    return BASE + file + "?k=" + k;
}

// Which of the two policies this document is actually carrying, read off the
// document rather than assumed from the build. The policy is a part the offline
// overlay includes, so what arrived is what was assembled -- but this still
// reads it rather than trusting it: a build assembled with the overlay whose
// document still says `script-src 'unsafe-eval'` first is the overlay not
// having applied, and that is a different finding from a policy that
// happened and did not hold.
function policyName() {
    try {
        var m = doc.querySelector('meta[http-equiv="Content-Security-Policy"]');
        var c = m ? String(m.getAttribute("content") || "") : "";
        if (!c) return "NONE";
        if (c.indexOf("default-src 'none'") === 0) return "OFFLINE";
        if (c.indexOf("script-src 'unsafe-eval'") === 0) return "DEFAULT";
        return "OTHER";
    } catch (_) {
        return "UNREADABLE";
    }
}

function fire() {
    var i;
    for (i = 0; i < ORDER.length; i++) marks[ORDER[i]] = "PEND";

    // connect-src, by the two names an app would reach for.
    try {
        win.fetch(url("off-probe.js", "fetch")).then(
            function () { mark("fetch", "OK"); },
            function () { mark("fetch", "ERR"); });
    } catch (_) { mark("fetch", "ERR"); }

    try {
        var x = new win.XMLHttpRequest();
        x.onload = function () { mark("xhr", "OK"); };
        x.onerror = function () { mark("xhr", "ERR"); };
        x.open("GET", url("off-probe.js", "xhr"), true);
        x.send();
    } catch (_) { mark("xhr", "ERR"); }

    // img-src and style-src. Both are narrowed to `data:` by the offline
    // policy and unrestricted by the default one, so both are variables.
    try {
        var img = new win.Image();
        img.onload = function () { mark("img", "OK"); };
        img.onerror = function () { mark("img", "ERR"); };
        img.src = url("off-probe.gif", "img");
    } catch (_) { mark("img", "ERR"); }

    try {
        var link = doc.createElement("link");
        link.rel = "stylesheet";
        link.onload = function () { mark("css", "OK"); };
        link.onerror = function () { mark("css", "ERR"); };
        link.href = url("off-probe.css", "css");
        doc.head.appendChild(link);
    } catch (_) { mark("css", "ERR"); }

    // The two constants. Refused by both policies; present here to say that the
    // document's policy is being enforced at all.
    try {
        var s = doc.createElement("script");
        s.onload = function () { mark("script", "OK"); };
        s.onerror = function () { mark("script", "ERR"); };
        s.src = url("off-probe.js", "script");
        doc.head.appendChild(s);
    } catch (_) { mark("script", "ERR"); }

    try {
        var f = doc.createElement("iframe");
        f.onload = function () { mark("frame", "OK"); };
        f.onerror = function () { mark("frame", "ERR"); };
        f.src = url("off-probe.html", "frame");
        if (doc.body) doc.body.appendChild(f);
    } catch (_) { mark("frame", "ERR"); }

    // The three an exfiltration would actually use, because none of them needs
    // to read a response and so none of them is stopped by CORS.
    try {
        mark("beacon",
            win.navigator.sendBeacon(url("off-probe.js", "beacon")) ? "OK" : "ERR");
    } catch (_) { mark("beacon", "ERR"); }

    try {
        var es = new win.EventSource(url("off-probe.js", "sse"));
        es.onopen = function () { mark("sse", "OK"); };
        es.onerror = function () { mark("sse", "ERR"); };
    } catch (_) { mark("sse", "ERR"); }

    try {
        var ws = new win.WebSocket("ws://127.0.0.1:" + PORT + "/off-probe.js?k=ws");
        ws.onopen = function () { mark("ws", "OK"); };
        ws.onerror = function () { mark("ws", "ERR"); };
    } catch (_) { mark("ws", "ERR"); }
}

function report() {
    var out = "OFFLINE-REPORT pol=" + policyName();
    for (var i = 0; i < ORDER.length; i++) {
        out += " " + ORDER[i] + "=" + marks[ORDER[i]];
    }
    doc.title = out + " DONE";
    win.setTimeout(escape_, 3000);
}

/*
 * The second act, and the one a content policy has no opinion about at all.
 *
 * `window.open` with an external url is a documented, first-class part of what
 * this file's preload gives every page. It ends at the desktop's URI handler on
 * Linux, at NSWorkspace on macOS and at ShellExecute on Windows, and there is
 * no tier check anywhere near any of them -- PR 3's comment says as much about
 * the macOS tight tier in passing: "an http url still reaches the browser, so
 * shell.openExternal is unaffected", which was that call's name at the time and
 * is the same `openExternal` record either way.
 *
 * So a page in an offline build can still make the machine fetch a url of its
 * choosing, with whatever it wants in the query string. It simply does it in
 * another program. `k=external` is that question.
 *
 * `k=navout` is the same question by the other route: a top-level navigation,
 * which no CSP directive here restricts. Every driver refuses it now -- and
 * gjs and Qt then hand the refused url to openExternal, which is the first
 * question again with the page not even having to ask.
 *
 * The title goes out before the navigation, or an engine that permits the
 * navigation loses the report along with the document.
 */
function escape_() {
    var ext = "THREW";
    try {
        // The url decides, not the target: this is http, so the override sends
        // it out rather than handing it to the engine. `null` back is the
        // documented answer for anything sent outward and not a refusal --
        // whether it left is the target server's log to say, not this call's.
        win.open(url("off-probe.html", "external"));
        ext = "SENT";
    } catch (_) {}
    doc.title = "OFFLINE-ESCAPE pol=" + policyName() + " ext=" + ext + " END";
    win.setTimeout(function () {
        try { win.location.href = url("off-probe.html", "navout"); } catch (_) {}
    }, 2000);
}

function start() {
    var tx = "none";
    try { tx = String(win.neutrino.transport); } catch (_) {}

    // The control that has to come first. A window wearing this title is a
    // build that came up, ran its page script and drove its native window --
    // which is exactly what a policy strict enough to stop the injected script
    // would break, and without it every "blocked" below is indistinguishable
    // from a corpse.
    doc.title = "OFFLINE-READY tx=" + tx + " pol=" + policyName();

    fire();
    // Long enough for a loopback answer and for an engine to give up on one.
    win.setTimeout(report, 8000);
}

// The one document this file is allowed to drive from. Once the navigation at
// the end has happened this same script is running in the target's document --
// the engines inject on the view, not on a document -- and without this it
// would fire all nine again from over there, and the log would stop saying
// which document reached the host.
function isAppDocument() {
    var p = "";
    try { p = String(win.location.protocol || ""); } catch (_) {}
    return p !== "http:" && p !== "https:";
}

function waitForReady() {
    // The iframe probe loads a document into this same view, and the engine
    // injects this script into it too. Without this the frame's copy fires all
    // nine again from inside the frame.
    try { if (win.top !== win) return; } catch (_) { return; }
    if (!isAppDocument()) return;

    if (doc.body && win.neutrino) {
        win.setTimeout(start, 2000);
    } else {
        win.setTimeout(waitForReady, 200);
    }
}
waitForReady();
