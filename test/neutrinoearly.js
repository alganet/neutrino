/*
 * The app under test is a page that navigates before its own load has
 * finished. This is the regression test for exactly that, and it fails against
 * the code this test arrived with.
 *
 * The author's script is injected at DOCUMENT_END, which runs after the
 * document is committed and before its load finishes. The gjs navigation guard
 * used to arm at FINISHED, so a navigation started from here was decided while
 * the guard was still down -- and the preload is registered on the engine, so
 * the page that arrives is handed the whole API and drives the native window.
 *
 * That hole reads as closed if you only look. On a document with nothing to
 * fetch, WebKitGTK delivers the policy decision on a later turn of the main
 * loop and the load finishes first, arming the guard in between. It is a race,
 * and this page picks the winner the way any hostile page would: a stylesheet
 * and an image on a socket that accepts and never answers, so this document's
 * load stays pending for as long as it likes.
 *
 * Which is why `ready` is reported and asserted. Without a stall the load
 * completes, the guard arms in time, and the navigation is refused for a reason
 * that has nothing to do with the fix -- a pass that proves nothing. A report
 * that says the document finished loading is a broken test, not a result.
 */
var win = eval("window");
var doc = eval("document");
var log = eval("console");

// Fixed here and in the workflow that starts test/stall.py. Nothing listening
// means the requests fail fast, the load completes, and `ready` says so.
var STALL = "http://127.0.0.1:8099/never";

function rawSend(record) {
    var encoded = encodeURIComponent(record);
    try { win.webkit.messageHandlers.neutrino.postMessage(record); } catch (_) {}
    try { win.chrome.webview.postMessage(record); } catch (_) {}
    try { log.log("__NEUTRINO__" + encoded); } catch (_) {}
    try { doc.title = "__NEUTRINO__" + encoded; } catch (_) {}
}

/*
 * Everything below runs at the top of the page script, synchronously. There is
 * no setTimeout in front of it on purpose: a navigation attempted from a later
 * turn is one the guard has already had time to arm against, which is the
 * window this test is not about.
 */
try {
    var sheet = doc.createElement("link");
    sheet.setAttribute("rel", "stylesheet");
    sheet.setAttribute("href", STALL + ".css");
    doc.head.appendChild(sheet);
} catch (_) {}
try {
    var img = doc.createElement("img");
    img.setAttribute("src", STALL + ".png");
    doc.body.appendChild(img);
} catch (_) {}

try {
    win.location.href = "https://neutrino-early-probe.invalid/";
} catch (_) {}

/*
 * Where this ends up is the whole result, and the title cannot carry it on its
 * own: when the navigation is allowed, the page that arrives is handed the same
 * API and sets the same title, so a title alone reads identically either way.
 * What separates them is which document is speaking. The host name never
 * resolves, so nothing leaves the machine whichever way it goes.
 */
function report() {
    var here = String(win.location.href);
    var escaped = here.indexOf("neutrino-early-probe.invalid") >= 0;
    var text = "EARLY at=" + (escaped ? "escaped" : "held") +
        // Which channel this build wired, so the verifier can tell which
        // engine's guard it is asserting against rather than inferring it from
        // the platform -- the same reason neutrinoattack.js reports it.
        " tx=" + String(win.neutrino ? win.neutrino.transport : "none") +
        " ready=" + String(doc.readyState) + " DONE";
    try {
        var el = doc.getElementById("early") || doc.createElement("div");
        el.id = "early";
        el.style.cssText = "font-family:monospace;font-size:18px;padding:16px;";
        el.textContent = text;
        if (!el.parentNode && doc.body) doc.body.appendChild(el);
    } catch (_) {}
    // Through the injected API, which is the channel a page that got here
    // would be using. If the host refuses it there is no title and the
    // verifier says so, which is the right answer for a build that renders
    // nothing.
    try { win.neutrino.window.setTitle(text); } catch (_) { rawSend("setTitle" + String.fromCharCode(31) + text); }
}

win.setTimeout(report, 6000);
