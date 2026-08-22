// The app under test is hostile page content. Every check here is something a
// page can attempt on its own, and the result is reported through the one
// channel it is supposed to have -- so a build where nothing renders cannot
// pass by refusing everything, because it would not report either.
//
// Results ride in the window title because that is what all three verifiers can
// already read. The final title is set once and then left alone, so a verifier
// that arrives late still sees it.
var win = eval("window");
var doc = eval("document");
var log = eval("console");

var SEP = String.fromCharCode(31);
var results = {};

// Recorded from the first report onwards, so a build where the navigation
// check never gets that far says PENDING rather than dropping the field and
// leaving a verifier to match a name that is not there.
results.postnav = "PENDING";

// Reaching past the injected API, the way an attacker would. Every transport is
// tried; the ones that do not belong to this platform are inert, and the host is
// supposed to be the thing that decides, not the sender.
function rawSend(record) {
    var encoded = encodeURIComponent(record);
    try { win.webkit.messageHandlers.neutrino.postMessage(record); } catch (_) {}
    try { win.chrome.webview.postMessage(record); } catch (_) {}
    try { log.log("__NEUTRINO__" + encoded); } catch (_) {}
    try { doc.title = "__NEUTRINO__" + encoded; } catch (_) {}
}

function geometry() {
    return win.innerWidth + "x" + win.innerHeight;
}

function show(text) {
    var el = doc.getElementById("attack") || doc.createElement("div");
    el.id = "attack";
    el.style.cssText = "font-family:monospace;font-size:18px;padding:16px;";
    el.textContent = text;
    if (!el.parentNode) doc.body.appendChild(el);
}

function report(navState) {
    var text = "ATTACK" +
        // Which channel the host is listening on, so a verifier asserts against
        // what this build actually does rather than against what its platform
        // used to do.
        " tx=" + String(win.neutrino.transport) +
        " wire=" + results.wire +
        " forge=" + results.forge +
        " raw=" + results.raw +
        " base=" + results.base +
        " inline=" + results.inline +
        " navdata=" + results.navdata +
        " postnav=" + results.postnav +
        " nav=" + navState +
        // Only the settled report says DONE. The pending one is a snapshot
        // taken before a navigation that may destroy this document, so a
        // verifier has to be able to tell it apart from the real answer
        // rather than reading whichever arrived first.
        (navState === "PENDING" ? "" : " DONE");
    show(text);
    win.neutrino.window.setTitle(text);
}

// A forged record placed in the document title. On any platform whose transport
// is not the title this must do nothing at all; where the title IS the
// transport it will be obeyed, and saying so is the point of measuring it.
function checkForge(next) {
    // Each check reads its own before-value. Sharing one baseline across all of
    // them means a check that legitimately changed the window makes every later
    // check report a change it did not cause -- which is exactly what happened
    // on Windows, where the title is the transport and the forge really is
    // obeyed.
    var before = geometry();
    doc.title = "__NEUTRINO__" + encodeURIComponent("resize" + SEP + "333" + SEP + "333");
    win.setTimeout(function () {
        results.forge = (geometry() === before) ? "REFUSED" : "OBEYED";
        next();
    }, 1500);
}

// Malformed records straight down the real transport: wrong arity, a field
// carrying code where a number belongs, an action nobody implements, and a
// close that arrives with a payload it should not have. If close is honoured
// the window dies here and no result is ever reported, which is itself the
// loudest possible failure.
function checkRaw(next) {
    var before = geometry();
    var records = [
        "resize" + SEP + "1" + SEP + "2" + SEP + "3",
        "resize" + SEP + "222;GLib.spawn_command_line_sync('true')" + SEP + "222",
        "resize" + SEP + "-222" + SEP + "-222",
        "evalThis" + SEP + "whatever",
        "close" + SEP + "x"
    ];
    var i = 0;
    // Sent one at a time rather than in a burst. Where the transport is a
    // polled document title the host only ever observes the last value written,
    // so a burst would have five records refused because four were never
    // delivered, and that reads as a pass without being one.
    function step() {
        if (i < records.length) {
            rawSend(records[i]);
            i++;
            win.setTimeout(step, 400);
            return;
        }
        win.setTimeout(function () {
            results.raw = (geometry() === before) ? "REFUSED" : "OBEYED";
            next();
        }, 1000);
    }
    step();
}

// The control, and the reason any of the refusals above mean anything. rawSend
// reaches past the injected API on purpose, and a transport that silently
// dropped everything would report every attack as refused while proving
// nothing. So one well-formed record goes down the same path, and it has to be
// obeyed. If this says DEAD, every REFUSED beside it is worthless.
function checkWire(next) {
    var before = geometry();
    rawSend("resize" + SEP + "640" + SEP + "480");
    win.setTimeout(function () {
        results.wire = (geometry() === before) ? "DEAD" : "LIVE";
        next();
    }, 1500);
}

/*
 * The document carries no script of its own -- this file's code is injected by
 * the engine -- so the policy can forbid inline script outright. This is the
 * check that says whether it really does, and unlike the frame check it can be
 * read from here: the script it adds runs in this same realm, so the flag it
 * sets is visible. Removing script-src from the policy makes this report RAN.
 */
function checkInline(next) {
    win.__neutrinoInlineRan = false;
    try {
        var tag = doc.createElement("script");
        tag.textContent = "window.__neutrinoInlineRan = true;";
        doc.body.appendChild(tag);
    } catch (_) {}
    win.setTimeout(function () {
        results.inline = win.__neutrinoInlineRan ? "RAN" : "BLOCKED";
        next();
    }, 800);
}

/*
 * The same-null-origin document that is actually reachable.
 *
 * Every engine here already refuses to navigate the top frame to a data: url --
 * "Not allowed to navigate top frame to data URL" -- so that route is closed by
 * the engine and not by anything in this project. A frame is the route that is
 * left: srcdoc is same-null-origin, and where a preload is registered on the
 * engine rather than inlined in the markup, whatever loads in that frame can be
 * handed its own copy of the API.
 *
 * Two things are supposed to stop it. frame-src 'none' should keep the frame
 * from running at all, and where it runs anyway the injection is main-frame
 * only and the host checks which frame a message came from. So this reports
 * whether the frame ran, and if it managed to drive the window it says so in
 * the title, which the verifier treats as an escape rather than a result.
 */
function checkFrame(next) {
    // This one reports nothing of its own, deliberately.
    //
    // Whether the frame loaded is not observable from here in a way worth
    // trusting: this document has no origin, so a child gets a *different*
    // opaque origin and cannot reach back, and load does not fire for srcdoc in
    // WebKitGTK at all -- measured, along with a data: frame that reported
    // loading and not loading under the same policy on consecutive runs. A
    // field that reads the same whatever the configuration is not a control,
    // and one that disagrees with itself is worse.
    //
    // What is worth asserting is the only thing that matters: if a frame drives
    // the native window, it says so in the title, and the verifier treats that
    // as an escape rather than a result. That assertion can fail, which is more
    // than the other could say.
    var escape = "<script>" +
        "try{window.neutrino.window.setTitle('ATTACK-FRAME-ESCAPED');}catch(e){}" +
        "<\/script>";
    try {
        var viaSrcdoc = doc.createElement("iframe");
        viaSrcdoc.setAttribute("srcdoc", escape);
        doc.body.appendChild(viaSrcdoc);
    } catch (_) {}
    try {
        var viaData = doc.createElement("iframe");
        viaData.setAttribute("src", "data:text/html," + encodeURIComponent(escape));
        doc.body.appendChild(viaData);
    } catch (_) {}
    win.setTimeout(next, 2000);
}

// base-uri 'none' in the document's content policy. A page that can move the
// base can silently repoint every relative url in the document.
function checkBase() {
    var before = String(doc.baseURI);
    try {
        var tag = doc.createElement("base");
        tag.setAttribute("href", "https://neutrino-base.invalid/");
        doc.head.appendChild(tag);
    } catch (_) {}
    results.base = (String(doc.baseURI) === before) ? "REFUSED" : "OBEYED";
}

/*
 * Both navigation checks are attempted after everything else has been
 * reported, because on an engine that permits either one this document stops
 * existing mid-check.
 *
 * The data: one is the interesting case. It is same-null-origin, so it is the
 * navigation an origin check cannot tell from the app's own document, and on
 * engines where the preload is registered rather than inlined the page that
 * arrives inherits the whole API. So the document navigated to does not just
 * sit there: it tries to drive the native window. Three outcomes, all
 * distinguishable from outside -- the navigation is refused and this document
 * survives to say so; or it is allowed and the host refuses its messages, so
 * the last report stands; or it is allowed and obeyed, and the title says
 * ATTACK-DATA-ESCAPED, which is a real escape and not a warning.
 */
function checkNavData(next) {
    results.navdata = "PENDING";
    report("PENDING");
    win.setTimeout(function () {
        try {
            win.location.href = "data:text/html," + encodeURIComponent(
                "<html><head><title>neutrino data probe</title></head><body>" +
                "<script>try{window.neutrino.window.setTitle(" +
                "'ATTACK-DATA-ESCAPED');}catch(e){}<\/script></body></html>"
            );
        } catch (_) {}
        win.setTimeout(function () {
            // Still the same document, so the navigation was refused.
            results.navdata = "REFUSED";
            next();
        }, 3000);
    }, 1000);
}

// The host name never resolves, so nothing leaves the machine either way.
//
// What happens after the refusal is measured too, and is a separate question
// from whether the refusal happened. Only the macOS driver asks who sent a
// message; gjs and Qt take any record the transport carries, which means the
// navigation guard is the only thing standing between a page that moved itself
// and the native window. Where the guard held, this document is still the
// app's own and a well-formed record should be obeyed -- so OBEYED here is the
// expected reading and not an escape. Where the guard did not hold, the
// document answering is no longer the app's, and the same OBEYED is the whole
// finding. Recorded, not asserted, until the probing says which of those this
// is measuring on each engine.
function checkNav() {
    report("PENDING");
    win.setTimeout(function () {
        try { win.location.href = "https://neutrino-must-refuse.invalid/"; } catch (_) {}
        win.setTimeout(function () {
            var before = geometry();
            rawSend("resize" + SEP + "660" + SEP + "500");
            win.setTimeout(function () {
                results.postnav = (geometry() === before) ? "REFUSED" : "OBEYED";
                report("REFUSED");
            }, 1500);
        }, 3000);
    }, 1000);
}

function start() {
    show("attacking");
    win.neutrino.window.setTitle("ATTACK-READY");
    win.setTimeout(function () {
        checkForge(function () {
            checkRaw(function () {
                checkWire(function () {
                    checkBase();
                    checkInline(function () {
                    checkFrame(function () {
                        checkNavData(function () {
                            checkNav();
                        });
                    });
                    });
                });
            });
        });
    }, 1000);
}

function waitForReady() {
    if (doc.body && win.neutrino) {
        // Same reason neutrinotest waits: the whole sequence is over in about
        // fifteen seconds and a verifier that is not watching by then misses
        // every step it will ever get.
        win.setTimeout(start, 8000);
    } else {
        win.setTimeout(waitForReady, 200);
    }
}
waitForReady();
