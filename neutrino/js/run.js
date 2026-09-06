    /*
     * Which engine is running is decided by which branch of the
     * conditional-compilation block this program was built from, so the
     * answer is already in the file by the time this is called: jsc.exe
     * compiled jsc/dispatch.jsc and nobody else did, every other engine
     * compiled else/engine.js and jsc.exe did not. This hands over to
     * whichever one is here.
     *
     * It used to ask, and asking cost more than it looks. Five hasGlobalExpr
     * calls, each an eval of a string, because this function was compiled by
     * a typed compiler that resolves globals and has none of the four other
     * engines' names. That is why the document's content policy carried
     * 'unsafe-eval': the page ran this on load. Both are gone.
     */
    NeutrinoWebview.run = function () {
        if (!this.runEngine) {
            throw new Error("Unsupported JS runtime for webview.js");
        }
        this.runEngine();
    };

    /*
     * The difference between "this lane cannot start" and "this program
     * failed", which the launcher reads as the difference between trying
     * the next engine and stopping. Tagged rather than matched on its
     * message, because the shell's decision must not depend on the spelling
     * of a sentence anyone might reword.
     */
    NeutrinoWebview.engineUnavailable = function (message) {
        var err = new Error(message);
        err.neutrinoEngineUnavailable = true;
        return err;
    };
