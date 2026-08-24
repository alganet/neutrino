// The app under test is a page that navigates itself away, on a build where
// the navigation can actually arrive.
//
// test/neutrinoattack.js already tries this, at a host that never resolves --
// which test/early-target.html's own comment says is not a test: the load fails
// on its own and a driver with no guard reports the same "held" as one with a
// guard. So on Windows, the platform with no navigation guard at all, nothing
// has ever measured what happens when the page really does leave.
//
// This file is that measurement. It is the app's page script, so the engine
// injects it into every document the view creates -- including the one this
// page navigates to, which is half of what is being measured. The other half is
// what that document can then do, and test/nav-target.html reports it through
// the server's request log rather than through the window.
var win = eval("window");
var doc = eval("document");

// Set here, in the page script, on whatever document this happens to be
// running in. test/nav-target.html reads it: if it is defined over there, the
// app author's own code re-ran inside a remote origin's document.
win.__neutrinoNavProbe = 1;

// The port the workflow serves test/ on. Not an environment read -- there is no
// environment in a page -- and not a configurable, because the harness and this
// file have to agree on one number.
var TARGET = "http://127.0.0.1:8097/nav-target.html";

function show(text) {
    var el = doc.getElementById("nav") || doc.createElement("div");
    el.id = "nav";
    el.style.cssText = "font-family:monospace;font-size:18px;padding:16px;";
    el.textContent = text;
    if (!el.parentNode && doc.body) doc.body.appendChild(el);
}

// The one document this file is allowed to drive from. Once the navigation has
// happened this same script is running in the target's document, and without
// this it would navigate again, forever, and the lane would measure a loop.
function isAppDocument() {
    var p = "";
    try { p = String(win.location.protocol || ""); } catch (_) {}
    return p !== "http:" && p !== "https:";
}

function start() {
    var tx = "none";
    try { tx = String(win.neutrino.transport); } catch (_) {}

    show("navigating");
    // The control. A window wearing this title is a build that came up, ran its
    // page script and drove its native window -- so everything after it that
    // reports nothing is reporting a refusal and not a corpse.
    try { win.neutrino.window.setTitle("NAV-READY tx=" + tx); } catch (_) {}

    // A window opened from the app's document, before the app's document goes
    // away. Whether one arrives is the NewWindowRequested question, and the
    // target says what it was handed when it gets there.
    win.setTimeout(function () {
        var opened = "THREW";
        try {
            opened = win.open(TARGET + "?probe=popup") ? "HANDLE" : "NULL";
        } catch (_) {}
        try {
            win.neutrino.window.setTitle("NAV-POPUP tx=" + tx + " opened=" + opened);
        } catch (_) {}

        // And then the navigation itself. From here this document may stop
        // existing, so nothing after this line is promised to run.
        win.setTimeout(function () {
            try { win.location.href = TARGET + "?probe=nav"; } catch (_) {}
        }, 3000);
    }, 2000);
}

function waitForReady() {
    if (!isAppDocument()) {
        // The remote document. Nothing to do here but be evidence.
        return;
    }
    if (doc.body && win.neutrino) {
        win.setTimeout(start, 6000);
    } else {
        win.setTimeout(waitForReady, 200);
    }
}
waitForReady();
