/*
 * A probe, not a test. Nothing here asserts; the answers leave through the
 * drivers' testing-tier trace and are read off the run's annotations.
 *
 * PR 5 proposes one sender check for all three engines -- ask the view what it
 * is currently showing before trusting a message -- and proposes arming the
 * gjs navigation guard at COMMITTED instead of FINISHED. Both rest on facts
 * about the engines that have never been measured here:
 *
 *   1. What each view answers when asked for its current uri, at the moment a
 *      message arrives. That string is what isTrustedView() would be judging.
 *      gjs loads with a null base url, this file's macOS driver loads with a
 *      file: base, and QtWebEngine hands the document over as a data: url --
 *      three different answers to the same question, and an origin rule that
 *      refuses any of them locks the app out of its own document silently.
 *
 *   2. Whether the page script really does run before the load has finished.
 *      That is the whole of finding 5's second half: the guard is armed at
 *      FINISHED and the author's script is injected at DOCUMENT_END, and if
 *      DOCUMENT_END comes first there is a window in which a navigation is
 *      allowed.
 *
 * Neither is observable from in here -- both are things only the host can see.
 * So this sends marks at moments whose ordering matters and lets the driver
 * record what it saw when each arrived. What this file is responsible for is
 * that the marks happen at the right moments, and that it says plainly whether
 * it ran at all: a probe that renders nothing produces an empty trace, which
 * would otherwise read exactly like an engine that answers nothing.
 */
var win = eval("window");
var doc = eval("document");
var log = eval("console");

var SEP = String.fromCharCode(31);

/*
 * Past the injected API on purpose, the same way neutrinoattack.js does it.
 * The mark has to be able to leave before window.neutrino is worth trusting,
 * and every transport that is not this platform's is inert.
 */
function rawSend(record) {
    var encoded = encodeURIComponent(record);
    try { win.webkit.messageHandlers.neutrino.postMessage(record); } catch (_) {}
    try { win.chrome.webview.postMessage(record); } catch (_) {}
    try { log.log("__NEUTRINO__" + encoded); } catch (_) {}
    try { doc.title = "__NEUTRINO__" + encoded; } catch (_) {}
}

/*
 * "probeMark" is not an action any router implements, so every host drops it
 * after tracing that it arrived. That is deliberate: a mark must not be able to
 * change the window, or the ordering it is measuring would be confounded by
 * whatever it did.
 */
function mark(name) {
    rawSend("probeMark" + SEP + name);
}

// The very top of the page script. Nothing has yielded yet, no timer has been
// set, and on gjs this is running from a DOCUMENT_END user script -- so the
// load state the driver records beside this mark is the answer to question 2.
mark("top");

function show(text) {
    var el = doc.getElementById("probe") || doc.createElement("div");
    el.id = "probe";
    el.style.cssText = "font-family:monospace;font-size:18px;padding:16px;";
    el.textContent = text;
    if (!el.parentNode && doc.body) doc.body.appendChild(el);
}

try {
    doc.addEventListener("DOMContentLoaded", function () { mark("domcontentloaded"); }, false);
    win.addEventListener("load", function () { mark("load"); }, false);
} catch (_) {}

/*
 * A mark from a later turn of the event loop, so the trace carries the view's
 * answer both during the load and long after it settled. If those two disagree
 * the check has to be written against the later one, and knowing that before
 * writing it is the point of asking twice.
 */
function settle() {
    mark("settled");
    win.setTimeout(function () {
        // The positive control, and the only thing here that is visible from
        // outside: a title means the document rendered, the injected API
        // arrived, and the transport carried a record the host acted on. An
        // empty trace next to a missing title is a probe that never ran; an
        // empty trace next to this title is an engine that answered nothing.
        var text = "PROBE tx=" + String(win.neutrino ? win.neutrino.transport : "none") +
            " api=" + (win.neutrino ? "YES" : "NO") + " DONE";
        show(text);
        try { win.neutrino.window.setTitle(text); } catch (_) {}
    }, 1500);
}

function waitForReady() {
    if (doc.body && win.neutrino) {
        show("probing");
        win.setTimeout(settle, 3000);
    } else {
        win.setTimeout(waitForReady, 200);
    }
}
waitForReady();
