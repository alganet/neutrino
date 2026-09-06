    /*
     * Where a line goes on every engine but the Windows launcher.
     *
     * js/note.js calls this and does not know what is in it, which is the
     * point: `printerr` is gjs's, `console` is everyone else's, and both are
     * globals a typed compiler resolves and refuses. Written as three evals in
     * the shared file, they were also three evals that a browser would run --
     * which is a reason a document had to allow eval to report a problem.
     */
    NeutrinoWebview.noteOut = function (line) {
        if (typeof printerr !== "undefined") {
            printerr(line);
            return;
        }
        if (typeof console === "undefined") {
            return;
        }
        if (console.warn) {
            console.warn(line);
            return;
        }
        if (console.log) {
            console.log(line);
        }
    };
