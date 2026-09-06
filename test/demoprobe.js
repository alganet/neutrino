// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// Appended to pages/demo/app.js by test/demoapp.sh, and it is the whole of the
// difference between the app under test here and the app on the download page.
//
// The published sample app is the one artifact in this tree that nobody ran.
// Every suite here builds its own probe, and each of those waits for a document
// by hand because it was written by someone who knew which lanes needed it --
// so the one app written the way the README tells an author to write one was
// also the one app with no instrument on it. It shipped with a Close button
// that did nothing on Windows, and what found that was a person on Windows
// Home.
//
// This adds no behaviour. It reads back what the app put on the page and puts
// it in the window title, which is the one channel a verifier outside the
// process can see. Three outcomes, and they are different readings rather than
// degrees of the same one:
//
//   no DEMOPROBE title at all   the app's own script threw before this line
//   eng=UNREADABLE              the early shell was not on the page, so the app
//                               could not read its own markup
//   eng=WebView2 tx=webmessage  the app ran, found its markup, and filled it in
//
// The second is exactly what the demo did on Windows for as long as the page
// script ran before the parser, and the first is what it would do if the app
// were written without the null guards it happens to carry.
//
// ES5 and no line reading NeutrinoWebview.run(), which are the rules the app
// this is appended to keeps. It used to say `eval` for the globals as well:
// this file names none of its own, taking `win` and `doc` from pages/demo/app.js
// above it, and those are bare now -- an app is the @else branch, jsc.exe does
// not compile it, and the document's policy forbids eval outright.

// The dwell verify-std.sh's harnesses lift out of a probe. Nothing here holds a
// state, so this is the one wait: long enough for a slow runner to have painted
// and short enough that a verifier watching for the title is still watching.
var DWELL = 1500;

function probeRead(id) {
    try {
        var node = doc.getElementById(id);
        if (!node) { return "UNREADABLE"; }
        var text = String(node.textContent || "");
        // The ellipsis the markup ships with, by code point rather than as a
        // literal: this file ends up inside a polyglot that four compilers read
        // and one of them is jsc.exe, and a non-ASCII byte in it is a question
        // nobody needs to answer. An element that is on the page and was never
        // filled in is a third reading again -- the app ran and its readings did
        // not arrive -- and it must not look like either of the two above.
        if (text === "" || (text.length === 1 && text.charCodeAt(0) === 8230)) {
            return "UNFILLED";
        }
        // Down to what a window title carries through two window managers and a
        // process list without anyone having to quote it. The separator here is
        // a space, so a value may not contain one.
        return text.replace(/[^A-Za-z0-9.:#_-]+/g, "_");
    } catch (e) {
        return "THREW";
    }
}

function probeReport() {
    doc.title = "DEMOPROBE eng=" + probeRead("engine") +
        " tx=" + probeRead("transport") +
        " size=" + probeRead("size") +
        " desktop=" + probeRead("scheme") +
        " bound=" + (doc.getElementById("close") &&
            doc.getElementById("close").onclick ? "yes" : "no") +
        " END";
}

win.setTimeout(probeReport, DWELL);
