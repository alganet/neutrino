    NeutrinoWebview.hasGlobalExpr = function (expression) {
        try {
            return eval(expression);
        } catch (_) {
            return false;
        }
    };

    /*
     * Where this file's document begins and where it ends -- decided once,
     * so that the two halves cut out of it below cannot come from different
     * places.
     *
     * This file's JavaScript, including whatever an author spliced into
     * runWeb, used to be an inline script inside the document it loads,
     * which meant the document's content policy had to permit inline script
     * and could never say script-src 'none'. Every driver injects the
     * preload through its engine, so the page's own code goes the same way
     * and the document carries no executable content at all. What that buys
     * is worth the trouble: an injection bug in someone's app cannot run
     * script in this document, because nothing in the document is allowed
     * to.
     *
     * All of which rests on the cut being in the right place, and the two
     * cuts used to be taken independently -- the document from the first
     * `<script` after the doctype, the page script from the first one in
     * the whole file. They agreed because a test said they had to.
     *
     * Every index below is found or the source is refused, and refusing is
     * the point. There used to be a fallback: no doctype meant "return the
     * whole file cut at the first `<script`", and no script tag or no
     * terminator meant an empty page script that every driver injected
     * without a word. Neither of those is ever the right answer, and on
     * this file the first is not even a near miss -- the string being
     * searched for appears in the source of the function searching for it,
     * a few lines below, inside the page script region. Measured: the
     * document that came out was 186 bytes of this function, it carried no
     * content policy at all on any of the four engines, and the page script
     * was injected into it whole.
     */
    NeutrinoWebview.locateDocument = function (content) {
        var text = String(content || "");
        var lower = text.toLowerCase();

        var start = lower.indexOf("<!doctype html");
        if (start < 0) {
            return { error: "there is no <!doctype html> in it" };
        }

        // Anchored at the doctype, which is what makes the two halves agree
        // by construction rather than by anyone remembering to check.
        var tag = text.indexOf("<script", start);
        if (tag < 0) {
            return { error: "nothing opens a script after the doctype" };
        }

        // Exactly one, and this is the guard for the shape that measured
        // worst. A doctype above the document -- a line in the shell region
        // naming it is enough -- starts the cut there, and the document that
        // comes out has the launcher's own text ahead of its <head>. A
        // content policy meta that is not a child of head is in the DOM and
        // is not a policy: Chromium enforced none of it, WebKit enforced
        // only the element-driven half, and the page reported the policy it
        // could see the whole time. Nothing downstream can tell that apart
        // from a policy that held, so it is refused here.
        var second = lower.indexOf("<!doctype html", start + 1);
        if (second >= 0 && second < tag) {
            return { error: "the document names its doctype more than once" };
        }

        var open = text.indexOf(">", tag);
        if (open < 0) {
            return { error: "the script tag after the doctype is never closed" };
        }

        var end = text.lastIndexOf("//</script>");
        if (end <= open) {
            return { error: "nothing closes the page script" };
        }

        return { start: start, tag: tag, open: open, end: end };
    };

    // Both halves go through it, so a file this launcher cannot split fails
    // once, in one place, saying which part of the shape was missing --
    // rather than twice, silently, in opposite directions.
    NeutrinoWebview.splitOrThrow = function (content) {
        var at = this.locateDocument(content);
        if (at.error) {
            throw new Error(
                "neutrino: cannot tell this file's document from its script: " + at.error);
        }
        return at;
    };

    /*
     * The document, with the script taken out of it.
     *
     * The tail used to be fabricated -- "<body></body></html>" appended to
     * whatever the head cut produced -- so the document every engine loaded
     * had an empty body no matter what the file said. That is why the demo
     * blinked: the first paint was this launcher's default style over
     * nothing, and the app's own markup arrived a frame or more later, from
     * script.
     *
     * The body now opens on the document line, above the script tag, which
     * is where the head cut already ends. So the markup an author builds in
     * is in the first paint rather than after it, and this function no
     * longer invents a document that is not in the file -- it returns the
     * file's own, minus the script element. `<script>` inside `<body>` is
     * valid HTML, so the file read directly by a browser is still the same
     * document.
     */
    NeutrinoWebview.extractHtmlDocument = function (content) {
        var text = String(content || "");
        var at = this.splitOrThrow(text);
        return text.substring(at.start, at.tag) + "</body></html>";
    };

    // The other half: everything the document used to carry, handed to the
    // engine to inject instead. Stops before the closing sentinel, which is
    // markup pretending to be a comment and is not wanted in either half.
    NeutrinoWebview.extractPageScript = function (content) {
        var text = String(content || "");
        var at = this.splitOrThrow(text);
        return text.substring(at.open + 1, at.end);
    };

    NeutrinoWebview.getMacScriptPath = function (ObjCRef, dollar) {
        var fileManager = dollar.NSFileManager.defaultManager;
        var currentDir = String(fileManager.currentDirectoryPath);

        var envPathObj = dollar.NSProcessInfo.processInfo.environment.objectForKey("NEUTRINO_SCRIPT_PATH");
        if (envPathObj) {
            var envPath = String(envPathObj);
            if (envPath && fileManager.fileExistsAtPath(envPath)) {
                return envPath;
            }
        }

        var argv = [];
        try {
            argv = ObjCRef.deepUnwrap(dollar.NSProcessInfo.processInfo.arguments);
        } catch (_) {
            argv = [];
        }

        for (var i = argv.length - 1; i >= 0; i--) {
            var candidate = String(argv[i] || "");
            if (!candidate || /^-/.test(candidate)) {
                continue;
            }

            if (fileManager.fileExistsAtPath(candidate)) {
                return candidate;
            }

            var combined = currentDir + "/" + candidate;
            if (fileManager.fileExistsAtPath(combined)) {
                return combined;
            }
        }

        throw new Error("Could not resolve current script path on macOS.");
    };

    NeutrinoWebview.getLinuxScriptPath = function (importsRef) {
        var GLib = importsRef["gi"]["GLib"];
        var systemRef = importsRef["system"];
        var programPath = String(systemRef.programPath);
        if (!GLib.path_is_absolute(programPath)) {
            programPath = GLib.build_filenamev([GLib.get_current_dir(), programPath]);
        }
        return programPath;
    };

