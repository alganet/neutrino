/*
 * The destructive half of PR 5's probing, kept in its own app for that reason.
 *
 * Finding 5 says the gjs guard is disarmed until the load has finished while
 * the author's script already runs at DOCUMENT_END, so a navigation started
 * from the top of the page script is allowed. neutrinoprobe.js measures the
 * ordering; this measures the consequence, by taking the window and using it.
 *
 * It is separate because it can destroy its own document. A navigation that is
 * allowed replaces this page, and then nothing here reports anything ever
 * again -- which is why the measurement is not this file's report but the
 * driver's trace of the decision it made. The trace records the uri, the state
 * of the guard at that moment, and what the guard did, and it survives the
 * document that provoked it.
 *
 * The host never resolves, so whichever way the decision goes nothing leaves
 * the machine.
 */
var win = eval("window");
var doc = eval("document");
var log = eval("console");

var SEP = String.fromCharCode(31);

function rawSend(record) {
    var encoded = encodeURIComponent(record);
    try { win.webkit.messageHandlers.neutrino.postMessage(record); } catch (_) {}
    try { win.chrome.webview.postMessage(record); } catch (_) {}
    try { log.log("__NEUTRINO__" + encoded); } catch (_) {}
    try { doc.title = "__NEUTRINO__" + encoded; } catch (_) {}
}

function mark(name) {
    rawSend("probeMark" + SEP + name);
}

/*
 * Two marks bracketing the attempt, and both matter.
 *
 * "early-top" is the control: it says this file ran at all, and the load state
 * the driver records beside it is the state the guard was in when the
 * navigation below was decided. Without it an empty trace could mean the page
 * script never executed, which is a different finding entirely.
 *
 * "early-called" says the assignment returned rather than throwing. On an
 * engine that refuses synchronously that is all that separates "refused" from
 * "never attempted".
 */
mark("early-top");
try {
    win.location.href = "https://neutrino-early-probe.invalid/";
} catch (e) {
    mark("early-threw");
}
mark("early-called");

/*
 * If this document is still alive a second later, the navigation did not take
 * it -- either the guard refused it or the engine did. A later mark that never
 * arrives is the loud answer, and the one PR 5 exists to prevent.
 */
win.setTimeout(function () { mark("early-survived"); }, 1500);

win.setTimeout(function () {
    var text = "PROBE-EARLY survived DONE";
    try {
        var el = doc.createElement("div");
        el.style.cssText = "font-family:monospace;font-size:18px;padding:16px;";
        el.textContent = text;
        doc.body.appendChild(el);
    } catch (_) {}
    try { win.neutrino.window.setTitle(text); } catch (_) {}
}, 3000);
