var win = eval("window");
var doc = eval("document");

function startTests() {
    var el = doc.createElement("div");
    el.style.cssText = "font-family:monospace;font-size:24px;padding:20px;";
    doc.body.appendChild(el);

    var steps = [
        function () { el.textContent = "Step 0: Ready"; win.neutrino.window.setTitle("STEP0"); },
        function () { el.textContent = "Step 1: setTitle"; win.neutrino.window.setTitle("STEP1-Test Title"); },
        function () { el.textContent = "Step 2: resize"; win.neutrino.window.resize(500, 400); },
        function () { el.textContent = "Step 2: resize done"; win.neutrino.window.setTitle("STEP2"); },
        function () { el.textContent = "Step 3: move"; win.neutrino.window.move(0, 0); },
        function () { el.textContent = "Step 3: move done"; win.neutrino.window.setTitle("STEP3"); },
        function () {
            // Before TESTS DONE and not after it: the Windows sampler stops
            // watching the moment it sees that title, so a step behind it is
            // one that platform can never report.
            var verdict = checkTheme();
            el.textContent = "Step 4: theme -- " + verdict.detail;
            win.neutrino.window.setTitle(verdict.ok ? "THEMEOK" : "THEMEBAD");
        },
        function () { el.textContent = "TESTS DONE"; win.neutrino.window.setTitle("TESTS DONE"); },
        function () { el.textContent = "Closing window..."; win.neutrino.window.close(); }
    ];

    var current = 0;
    function runNext() {
        if (current < steps.length) {
            steps[current]();
            current++;
            if (current < steps.length) win.setTimeout(runNext, 1000);
        }
    }
    // The whole sequence takes about eight seconds, and a verifier that is not
    // watching by then misses steps it can never see again. verify-windows.ps1
    // compiles inline C# with Add-Type before its first poll, which on a cold
    // runner can cost longer than that -- so the app waits for its audience
    // rather than racing it.
    win.setTimeout(runNext, 8000);
}

// The desktop's palette, checked by the app rather than by four verifiers that
// would each have to know what a palette looks like. What lands in the title is
// a verdict; what lands on screen -- and therefore in every screenshot CI keeps
// -- is the reading itself, which is the only place the actual colours can be
// seen after the fact.
//
// `theme === null` is the positive control and the reason this check is worth
// running at all. Every other assertion here is about pure code that parse.sh
// already covers on every push; what only a real launch can say is whether the
// lane reached its toolkit. A lane that silently did not reports null, and null
// is distinguishable from a genuinely white desktop -- which is exactly why the
// launcher says null instead of filling the palette in with white.
// Every verdict is built on one line, and that is a constraint of where this
// file ends up rather than a style. build.sh splices it into runWeb(), which is
// inside the NeutrinoWebview object literal, and parse.sh lifts that object out
// again with a sed range that ends at the first line reading `    };`. A
// multi-line object literal closed at this indent ends the range early: the
// lift comes back truncated and node reports "Unexpected end of input" against
// a line number in a temporary file, which says nothing about the app that
// caused it. Measured, by writing one.
function verdict(ok, detail) {
    return { ok: ok, detail: detail };
}

function checkTheme() {
    var keys = ["background", "foreground", "base", "text",
                "accent", "accentText", "border"];
    var theme = win.neutrino.theme;
    if (!theme) {
        return verdict(false, "null -- this lane read no palette at all");
    }
    if (theme.scheme !== "dark" && theme.scheme !== "light") {
        return verdict(false, "scheme is " + theme.scheme);
    }
    var seen = [];
    for (var k in theme.colors) { seen.push(k); }
    if (seen.sort().join(",") !== keys.slice(0).sort().join(",")) {
        return verdict(false, "keys are " + seen.join(","));
    }
    var shown = [];
    for (var i = 0; i < keys.length; i++) {
        var value = theme.colors[keys[i]];
        if (!/^#[0-9a-f]{6}$/.test(String(value))) {
            return verdict(false, keys[i] + " is " + value);
        }
        shown.push(keys[i] + "=" + value);
    }
    return verdict(true, theme.source + " " + theme.scheme + " " + shown.join(" "));
}

function waitForReady() {
    if (doc.body && win.neutrino) startTests();
    else win.setTimeout(waitForReady, 200);
}
waitForReady();
