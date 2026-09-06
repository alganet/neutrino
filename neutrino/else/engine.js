    /*
     * Which engine is running, for every engine that is not the Windows
     * launcher -- and the whole of what makes this readable is that the
     * launcher is not one of the answers. It compiled the other branch.
     *
     * So the names can be named. This used to be five calls to hasGlobalExpr,
     * each handing eval a string like "typeof ObjC !== 'undefined' && typeof $
     * !== 'undefined'", because jsc.exe compiled this dispatch too and resolves
     * globals at compile time -- a bare `ObjC` was a compile error on the one
     * platform that has no ObjC. Every one of those strings is now an ordinary
     * expression.
     *
     * That is also what let the document's content policy become
     * `script-src 'none'`. It carried 'unsafe-eval' for exactly these five
     * calls: the page ran this dispatch on load, so the one document that is
     * meant to be unable to execute anything had to permit eval to find out
     * where it was. See js/policy.js.
     */
    NeutrinoWebview.runEngine = function () {
        if (typeof ObjC !== "undefined" && typeof $ !== "undefined") {
            this.runMacOS();
            return;
        }
        if (typeof imports !== "undefined" && imports.gi) {
            this.runGjs();
            return;
        }
        /*
         * Qt drives its own window from window.qml, and the PyGObject shim
         * drives GTK from Python; both host this file to reuse its decisions
         * rather than to be started by it, so the honest answer here is to
         * return having done nothing.
         *
         * Two flags and not one. This dispatch exists to say which engine is
         * running, and two lanes answering to a single name would make it say
         * the wrong thing in the one place anybody reads to find out.
         */
        if (typeof NeutrinoQml !== "undefined") {
            return;
        }
        if (typeof NeutrinoPy !== "undefined") {
            return;
        }
        if (typeof window !== "undefined" && typeof document !== "undefined") {
            this.runWeb();
            return;
        }
        throw new Error("Unsupported JS runtime for webview.js");
    };
