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

// Fixed here and in the workflow that starts test/stall.py. Nothing listening
// means the requests fail fast, the load completes, and `ready` says so.
var STALL = "http://127.0.0.1:8099/never";

/*
 * Where this page tries to go, and it has to be somewhere that answers.
 *
 * This was a host that never resolves, and the macOS probing showed what that
 * was worth: the provisional load fails on its own, the app's document is
 * never replaced, and `at=held` is what a driver with no navigation guard at
 * all reports. The same run measured this target arriving, the user scripts
 * being reinjected into it, and the page that got here speaking to the native
 * window. So the target is served by the workflow over loopback, the verifier
 * asserts it is being served before it believes anything, and nothing leaves
 * the machine either way.
 */
var TARGET = "http://127.0.0.1:8098/early-target.html";
var TARGET_MARK = "early-target.html";

/*
 * Where this ends up is the whole result, and the title cannot carry it on its
 * own: when the navigation is allowed, the page that arrives is handed the same
 * API and sets the same title, so a title alone reads identically either way.
 * What separates them is which document is speaking. The target is on loopback
 * and is served by the workflow, so nothing leaves the machine whichever way it
 * goes.
 */
function report() {
    var here = String(win.location.href);
    var escaped = here.indexOf(TARGET_MARK) >= 0;
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
    // The standard spelling, which is also the channel a page that got here
    // would be using: the host mirrors a document's title onto the native
    // window only for the document it loaded itself. So where the navigation
    // was allowed there is no title at all and the verifier says so, which is
    // the right answer for a build that renders nothing. It used to fall back
    // to a raw setTitle record when the API was missing; that record no longer
    // exists, and an assignment needs no API to reach.
    doc.title = text;
}

/*
 * The engine reinjects this script into whatever document arrives, which is the
 * hole under test -- so where the navigation was allowed, this runs again in
 * the page that got here. It must not navigate again from there: the target
 * answers now, so that would be a loop and no report would ever settle.
 * Arriving is the result. Report it and stop.
 */
if (String(win.location.href).indexOf(TARGET_MARK) >= 0) {
    win.setTimeout(report, 500);
} else {
    /*
     * Everything below runs at the top of the page script, synchronously. There
     * is no setTimeout in front of it on purpose: a navigation attempted from a
     * later turn is one the guard has already had time to arm against, which is
     * the window this test is not about.
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
        win.location.href = TARGET;
    } catch (_) {}

    win.setTimeout(report, 6000);
}
