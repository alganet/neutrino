// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// neutrinostddoc.js - whether `document.title` reaches the native window title.
//
// `neutrino.window.setTitle` has a standard spelling and it is an assignment:
// every browser makes `document.title` the window's title, and every one of the
// four engines under this launcher raises a signal when it changes --
// `notify::title`, `onTitleChanged`, KVO on `WKWebView.title`,
// `DocumentTitleChanged`. Nothing in this file connects any of them today, so
// the expected reading is that the native title does not move. The point of
// asking is that "expected" is not "measured", and one lane answering
// differently is a finding about that lane.
//
// It is its own app for one reason. If `document.title` *does* reach the window
// on some lane, then every later IPC title in the same run races the value the
// DOM is still holding, and a probe whose report channel is the window title
// cannot afford that. Nothing else here shares a process with this question.
//
// Three things make the sequence readable rather than merely present.
//
// It is bracketed by two controls sent through the wire. A run that shows no
// title at all and a run where the hook did nothing are the same empty reading
// otherwise; with the brackets, the second one still reports CTL and END.
//
// There are two DOM writes, not one. A marker that names one end of a gap
// cannot measure the gap: with a single DOM value, "the write reached the
// window" and "the window still shows the control" are told apart only by a
// value the control also produces.
//
// And the empty write comes before the read-back report rather than after it,
// so "does an empty title revert the window or stick" is asked against DOM2 --
// a value the DOM put there -- and not against a title the wire had just set.
//
// ES5 only, `eval("window")` and `eval("document")`: jsc.exe compiles this.
var win = eval("window");
var doc = eval("document");

// Lifted by the verifier, which fails its own control when its slowest turn
// came within it. Six states at this dwell is nine seconds after the window.
var DWELL = 1500;

function put(s) {
    var t = String(s);
    if (t.length > 1000) {
        t = "STD-OVER len=" + t.length + " " + t.substring(0, 900);
    }
    try { win.neutrino.window.setTitle(t); } catch (_) {}
}

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
function step1() { put("STD-DOC-CTL"); win.setTimeout(step2, DWELL); }
function step2() { dom("STD-DOC-DOM1"); win.setTimeout(step3, DWELL); }
function step3() { dom("STD-DOC-DOM2"); win.setTimeout(step4, DWELL); }
// The read-back is taken here, before the empty write, as well as after it.
// One of the two would have been enough to say the DOM accepted a value and
// neither says the window saw it -- but with both, a lane that refuses the
// empty write and a lane that never took DOM2 at all stop reading alike.
var RB_AT_DOM2 = "?";
function step4() {
    try { RB_AT_DOM2 = String(doc.title); } catch (_) { RB_AT_DOM2 = "threw"; }
    dom("");
    win.setTimeout(step5, DWELL);
}

// What the DOM says its own title is. This will read back DOM2 on every lane
// whether or not the native window ever saw it -- it is the document's account
// of itself, it is marked -SELF for that reason, and the verifier prints it
// without asserting it. The reading is the recorded native sequence above.
function step5() {
    var rb = "?";
    try { rb = String(doc.title); } catch (_) { rb = "threw"; }
    var tx = "none";
    try { tx = String(win.neutrino.transport); } catch (_) {}
    put("STD-DOC-RB-SELF rb2=[" + RB_AT_DOM2 + "] rb=[" + rb + "] tx=" + tx +
        " eng=" + engine() + " dwell=" + DWELL);
    win.setTimeout(step6, DWELL);
}

function step6() { put("STD-DOC-END"); }

function ready() {
    if (win.neutrino) { step1(); }
    else { win.setTimeout(ready, 16); }
}

ready();
