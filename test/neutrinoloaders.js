// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// neutrinoloaders.js - an app that comes up, says so, and stays up.
//
// loaders.sh launches this once per knob and reads the engine process from
// outside, so the app itself has nothing to measure. What it must not do is
// close: neutrinotest.js ends its sequence with window.close() about sixteen
// seconds in, and a probe that read the environment after that would be
// reading a process that had already gone -- which looks exactly like a name
// that never arrived.
var win = eval("window");
var doc = eval("document");

function ready() {
    if (doc.body && win.neutrino) {
        doc.body.textContent = "LOADERS";
        win.neutrino.window.setTitle("LOADERS READY");
    } else {
        win.setTimeout(ready, 200);
    }
}
ready();
