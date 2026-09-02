// alive.js - the smallest neutrino app that can answer netinstall's question
//
// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// What the suites here have to know about a launch is narrow, and it is the
// same on all three platforms: the confinement just applied still lets a
// webview start and still lets it run the page's script. One title says that.
//
// test/neutrinotest.js answers a different question -- neutrino's window
// contract, six states deep -- and it costs eleven seconds before its first
// one, because a verifier that arrives late has to still see state one. This
// file has no sequence to be late for: the title is set once and the window is
// then held until the suite kills it, so the answer is on screen from the
// moment it is true and stays there. Measured at about two seconds against the
// twenty-six that sequence takes.
//
// One title, set once, is enough, and that is a fact about the trust guard
// rather than an optimism. `NeutrinoWebview.acceptDocumentTitle` refuses a
// title from a document the view was not given, so a page that titled itself
// before the driver had armed would be refused and -- since nothing would
// change the title again -- never heard from. Every driver arms at the load it
// started and before any page script exists: gjs at COMMITTED, Qt immediately
// before it injects the preload, macOS at didCommitNavigation:, WebView2 at the
// turn of its loop where the navigation sink says the document arrived. The
// first statement in this file therefore cannot run before the arming, on any
// of the four.
//
// `doc.body` and not `doc.body && win.neutrino`, which is what neutrinotest.js
// waits for. The API being in scope is neutrino's claim and neutrino's lanes
// assert it on every push; making it a precondition here would mean an
// unrelated regression in it reporting itself as a sandbox that killed the
// webview. What this file needs is a document and a script that ran.
var win = eval("window");
var doc = eval("document");

// Two titles, and the second one is the whole of what this file learned in CI.
//
// The bare title says a script ran. It does not say the view ever got as far as
// a frame -- and that is the exact question the Windows tight tier turns on,
// because low integrity is documented to leave WebView2 with a window and no
// rendering. A probe that cannot tell those apart reports a tier viable on the
// one platform where it may not be.
//
// So the size is announced from inside a frame callback: requestAnimationFrame
// runs after layout and immediately before the engine would paint, so a
// viewport with real dimensions arriving through it is a view that got a
// surface, laid the document out on it and scheduled a frame. It is not proof
// that pixels reached the screen -- only a photograph is that, and this suite
// stopped taking them on purpose -- and the README says so in as many words.
//
// The bare title is still set first and unconditionally. If the frame never
// comes, the reading has to be "ran, no frame" and not "never ran", because
// those two have different causes and only one of them is about the sandbox.
function announce() {
    var el = doc.createElement("div");
    el.style.cssText = "font-family:monospace;font-size:24px;padding:20px;";
    el.textContent = "netinstall: the webview started and this script ran.";
    doc.body.appendChild(el);
    doc.title = "NETINSTALL-ALIVE";
    frame(function () {
        var w = win.innerWidth, h = win.innerHeight;
        el.textContent = "netinstall: a frame was scheduled at " + w + "x" + h + ".";
        doc.title = "NETINSTALL-ALIVE " + w + "x" + h;
    });
}

// rAF where there is one. The fallback is a timer, and it is weaker on purpose
// rather than by accident: a timer says layout happened, not that a frame was
// scheduled. Every engine this launcher drives has rAF, so the fallback is for
// an engine nobody here has met -- and the sizes it reports still answer the
// degenerate case, which is a viewport of 0x0.
function frame(fn) {
    if (typeof win.requestAnimationFrame === "function") win.requestAnimationFrame(fn);
    else win.setTimeout(fn, 100);
}

function waitForReady() {
    if (doc.body) announce();
    else win.setTimeout(waitForReady, 200);
}
waitForReady();
