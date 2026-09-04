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
// each other. It reads `interactive` on WebKit and WebView2 and `complete` on
// QtWebEngine -- a difference between engines and not between launchers, which
// is why it is reported and not asserted. What *is* asserted is `body0` below.
var RS0 = "?";
try { RS0 = String(doc.readyState); } catch (_) { RS0 = "threw"; }

// Whether the early shell was on the page when this file's first statement ran,
// and this one is an assertion on every lane.
//
// It used to be four lanes out of five. WebKitGTK takes a DOCUMENT_END user
// script, WKWebView injection time 1 and Qt runs the page script from
// LoadSucceeded, so on all four an app's first statement had its own markup in
// hand; WebView2 has one hook before a navigation and it runs before the parser
// has produced anything, so the fifth ran with `document.body` null. Nothing
// said so. The published sample app was written the way the other four allow --
// `getElementById("close").onclick = ...` -- and on Windows that threw on the
// first line, which is why the demo everybody downloads had a Close button that
// did nothing there and worked everywhere else.
//
// `doc.body` and not `doc.documentElement`, for the reason `ready()` at the
// bottom of neutrinostdwin.js gives: the parser inserts `<html>` before
// `<head>`, so documentElement is already there inside the window this is
// asking about.
var BODY0 = "?";
try { BODY0 = doc.body ? "yes" : "no"; } catch (_) { BODY0 = "threw"; }

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
    // WKWebView, which carries neither "Safari" nor any of the three above.
    // Added from a measurement and not from a guess: the previous round made
    // this branch print what it had actually read, and the macOS lane came back
    // `unknown[Mozilla/5.0 Macintosh Intel Mac OS X 10157 Apple]` -- an
    // AppleWebKit user agent with no product token on the end, because nothing
    // sets applicationNameForUserAgent. Last of the WebKit tests, so the three
    // engines above that also carry "AppleWebKit" have already been named.
    if (ua.indexOf("AppleWebKit") !== -1) { return "WebKit"; }
    // Not "unknown". The macOS lane has answered `eng=unknown` fifteen times a
    // run for as long as this function has existed -- WKWebView's user agent
    // does not carry any of the four names above -- and "unknown" is the one
    // reply that cannot be acted on: it does not say whether the string was
    // empty, or absent, or simply unrecognised. A slice of what was actually
    // read turns the next run into the measurement that settles it.
    //
    // Safe to change: nothing in any verifier matches on `eng=`, so this is
    // read by people and not by assertions.
    return ua === "" ? "unknown-empty-ua"
        : "unknown[" + ua.replace(/[^A-Za-z0-9.\/ ]/g, "").substring(0, 48) + "]";
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
        " body0=" + BODY0 +
        " rbe=[" + RB_AT_EMPTY + "] rbm=[" + RB_AT_MARK + "] tx=" + tx +
        " eng=" + engine() + " dwell=" + DWELL);
    win.setTimeout(step7, DWELL);
}

function step7() { dom("STD-DOC-END"); }

// The wait is for a document and not only for the API, and this suite is the
// one that had to learn why. `document.title` writes into the `<title>` of a
// `<head>`, and where there is neither the DOM's rule is to do nothing at all --
// so on WebView2, whose page script used to run at `loading`, the first report
// of the run went nowhere and the state it named was simply missing from the
// record. `doc.body` is the cheap proof that `</head>` has been passed, which
// is the same condition the four test apps have always waited on.
//
// It waits for something that has already happened now, on every lane, and
// BODY0 above is the measurement that says so. Kept anyway, and not out of
// caution: this is the probe that asserts the promise, so it must not be the
// probe that depends on it. A suite that stopped reporting the moment the
// promise broke would take its own failure off the record.
function ready() {
    if (doc.body && win.neutrino) { step1(); }
    else { win.setTimeout(ready, 16); }
}

ready();
