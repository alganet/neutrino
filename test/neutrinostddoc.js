// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// neutrinostddoc.js - whether `document.title` reaches the native window title.
//
// It used to expect no. Every one of the four engines takes the assignment into
// the DOM and carries it no further -- measured, all four, with the title bar
// never moving -- and this file recorded that. `neutrino.window.setTitle` was
// the spelling that did move it.
//
// The launcher now connects the signal each engine raises when a document's
// title changes: `notify::title` on the two WebKitGTK lanes, `onTitleChanged`
// on Qt, the view's own `title` on macOS, `DocumentTitleChanged` on WebView2.
// So the expected reading has flipped, and this is the suite that says whether
// it flipped on the lane it is running on.
//
// It is its own app for the reason it always was, turned around. The report
// channel of every suite in this tree is the window title, and on this lane it
// is now also the thing under test -- so nothing else here shares a process
// with the question.
//
// What the sequence has to separate, and how.
//
// A DOM write that reached the window and one that did not are told apart by
// the window: DOM1 and DOM2 are two writes, not one, because a marker naming
// one end of a gap cannot measure the gap.
//
// Two writes that the *gate* refuses follow them, and both are refusals with a
// visible shape: the window has to still be showing DOM2 afterwards. The empty
// one asks whether a document that stops naming itself takes the window's name
// away with it. The marked one asks whether a record can be delivered as a name
// -- it is the same string test/neutrinoattack.js plants, asked here on every
// lane rather than only on the three that run the attack app.
//
// And the read-backs are carried in one -SELF field at the end. They are the
// document's account of itself, so they are printed and not asserted; what they
// are for is telling "the write was refused by the window" from "the write
// never happened", which the recorded native sequence alone cannot do.
//
// ES5 only, `eval("window")` and `eval("document")`: jsc.exe compiles this.
var win = eval("window");
var doc = eval("document");

// Lifted by the verifier, which fails its own control when its slowest turn
// came within it. Seven states at this dwell is ten and a half seconds after
// the window.
var DWELL = 1500;

// The marker the transports use, spelled here the way an attacker would have to
// spell it. Built rather than written whole so that this file's own text does
// not carry a record a title-polling host could read out of it.
var MARK = "__NEUTRINO__";

// What the document called itself before this script ran a statement. On a
// build that passed no --title this is the launcher's default, and it is the
// name the window came up wearing -- the launcher puts the build's title into
// the document precisely so that the first title-changed signal of a launch
// carries the name the window already has.
var RB_AT_START = "?";
try { RB_AT_START = String(doc.title); } catch (_) { RB_AT_START = "threw"; }

// And what the document was at that moment, because the two answers explain
// each other. This is `interactive` on WebKit, `complete` on QtWebEngine and
// `loading` on WebView2 -- already measured, already recorded -- and on the
// lane that says `loading` the first statement runs before `<head>` exists.
// `document.title` has nothing to write into there and the assignment is a
// no-op by the DOM's own rule, so `rb0` reads empty on exactly the lane `rs0`
// says it would. Reported and not asserted: it is a platform difference and
// the wait below is what an app does about it.
var RS0 = "?";
try { RS0 = String(doc.readyState); } catch (_) { RS0 = "threw"; }

var RB_AT_EMPTY = "?";
var RB_AT_MARK = "?";

function dom(s) {
    try { doc.title = String(s); } catch (_) {}
}

function engine() {
    var ua = "";
    try { ua = String(win.navigator.userAgent || ""); } catch (_) { return "unknown"; }
    if (ua.indexOf("Edg") !== -1) { return "WebView2"; }
    if (ua.indexOf("QtWebEngine") !== -1) { return "QtWebEngine"; }
    if (ua.indexOf("Chrome") !== -1) { return "Chromium"; }
    if (ua.indexOf("Safari") !== -1) { return "WebKit"; }
    return "unknown";
}

// Each step names itself, so a state the harness never observed is reportable
// as that state and not as a hole in a chunked reading.
function step1() { dom("STD-DOC-CTL"); win.setTimeout(step2, DWELL); }
function step2() { dom("STD-DOC-DOM1"); win.setTimeout(step3, DWELL); }
function step3() { dom("STD-DOC-DOM2"); win.setTimeout(step4, DWELL); }

// The two the gate is supposed to refuse. Neither may show up in the window,
// and the window has to be still wearing DOM2 when each of them is over -- so
// they are held a full dwell apart like everything else, and the read-back is
// taken inside each hold rather than after both.
function step4() {
    dom("");
    win.setTimeout(function () {
        try { RB_AT_EMPTY = String(doc.title); } catch (_) { RB_AT_EMPTY = "threw"; }
        step5();
    }, DWELL);
}

function step5() {
    dom(MARK + encodeURIComponent("STD-DOC-FORGED"));
    win.setTimeout(function () {
        try { RB_AT_MARK = String(doc.title); } catch (_) { RB_AT_MARK = "threw"; }
        step6();
    }, DWELL);
}

// What the DOM says its own title was at each point. Marked -SELF because it is
// the document's account of itself; the verifier prints it and asserts the
// recorded native sequence instead.
function step6() {
    var tx = "none";
    try { tx = String(win.neutrino.transport); } catch (_) {}
    dom("STD-DOC-RB-SELF rb0=[" + RB_AT_START + "] rs0=" + RS0 +
        " rbe=[" + RB_AT_EMPTY + "] rbm=[" + RB_AT_MARK + "] tx=" + tx +
        " eng=" + engine() + " dwell=" + DWELL);
    win.setTimeout(step7, DWELL);
}

function step7() { dom("STD-DOC-END"); }

// The wait is for a document and not only for the API, and this suite is the
// one that had to learn why. `document.title` writes into the `<title>` of a
// `<head>`, and where there is neither the DOM's rule is to do nothing at all --
// so on WebView2, whose page script runs at `loading`, the first report of the
// run went nowhere and the state it named was simply missing from the record.
// `doc.body` is the cheap proof that `</head>` has been passed, which is the
// same condition the four test apps have always waited on.
function ready() {
    if (doc.body && win.neutrino) { step1(); }
    else { win.setTimeout(ready, 16); }
}

ready();
