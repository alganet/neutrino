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

function waitForReady() {
    if (doc.body && win.neutrino) startTests();
    else win.setTimeout(waitForReady, 200);
}
waitForReady();
