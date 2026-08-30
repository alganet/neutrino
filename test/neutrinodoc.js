// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// neutrinodoc.js - an app that says which read of the file it came out of.
//
// docswap.ps1 builds two artifacts from this file that differ in two places:
// a marker meta tag in the document region, and the constant below in the page
// script region. `boot` reads the file once and takes the page script from that
// read; the Windows driver reads it a second time inside the event loop and
// renders a document extracted from *that*. So the two markers name the two
// reads, and a title carrying one from each build is the finding -- without
// them a swap that landed before the first read and one that landed between
// the two are the same reading.
//
// Round 1 had only the document marker and could not tell those apart. It read
// doc=A at every delay it tried, including one where the file had been deleted,
// and could not say whether the second read had already happened or the delete
// had silently not.
//
// It reports on a timer, four times a second. The first document this script
// runs in is the about:blank the view is created on -- the page script is
// registered on the view and not on a document -- so a single reading taken
// when the API first appears is the wrong document every time, and the moment
// the right one arrives is half of what is being measured.
var BUILD = "X";

var win = eval("window");
var doc = eval("document");

// getElementsByTagName and not querySelector: this file is an app on the three
// engines that never run this probe, and the older spelling is the one all four
// of them have.
function marker() {
    var metas = doc.getElementsByTagName("meta");
    for (var i = 0; i < metas.length; i++) {
        if (String(metas[i].getAttribute("name")) === "nt-doc") {
            return String(metas[i].getAttribute("content") || "empty");
        }
    }
    return "none";
}

// A diagnostic beside the reading and never the reading. NavigateToString gives
// the document it creates the same about:blank the view started on, so this
// cannot separate "never navigated" from "navigated to the string"; the markers
// are what do that.
function where() {
    var u = "";
    try { u = String(win.location.href || ""); } catch (_) { return "unreadable"; }
    if (u.indexOf("about:blank") === 0) return "blank";
    if (u.indexOf("data:") === 0) return "data";
    if (u.indexOf("file:") === 0) return "file";
    return u ? "other" : "empty";
}

// Whether the content policy meta ended up where a content policy is read from.
// A meta element that is not a child of head is in the DOM and is not a policy,
// and both answer the same to anything that asks the document for it -- which
// is what round 1 measured on four engines.
function policyAt() {
    var metas = doc.getElementsByTagName("meta");
    for (var i = 0; i < metas.length; i++) {
        if (String(metas[i].getAttribute("http-equiv")) === "Content-Security-Policy") {
            return String((metas[i].parentNode && metas[i].parentNode.nodeName) || "?").toLowerCase();
        }
    }
    return "absent";
}

function report() {
    try {
        if (doc.body && win.neutrino) {
            doc.body.textContent = "DOCSWAP";
            doc.title = "DOCSWAP script=" + BUILD + " doc=" + marker() +
                " where=" + where() + " pol=" + policyAt();
        }
    } catch (_) {}
    win.setTimeout(report, 250);
}
report();
