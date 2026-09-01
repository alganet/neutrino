    NeutrinoWebview.run = function () {
        if (this.hasGlobalExpr("typeof System !== 'undefined' && System && System.Windows && System.Windows.Forms && System.Windows.Forms.Application")) {
            this.runWindows();
            return;
        }
        if (this.hasGlobalExpr("typeof ObjC !== 'undefined' && typeof $ !== 'undefined'")) {
            this.runMacOS();
            return;
        }
        if (this.hasGlobalExpr("typeof imports !== 'undefined' && !!imports.gi")) {
            this.runGjs();
            return;
        }
        if (this.hasGlobalExpr("typeof NeutrinoQml !== 'undefined'")) {
            return;
        }
        /*
         * The PyGObject lane's shim, which hosts this source in a
         * JavaScriptCore context and drives GTK from Python. It gets a flag
         * of its own rather than borrowing NeutrinoQml: this dispatch
         * exists to say which engine is running, and two lanes answering to
         * one name would make it say the wrong thing in the one place
         * anybody reads to find out.
         */
        if (this.hasGlobalExpr("typeof NeutrinoPy !== 'undefined'")) {
            return;
        }
        if (this.hasGlobalExpr("typeof window !== 'undefined'")) {
            this.runWeb();
            return;
        }
        throw new Error("Unsupported JS runtime for webview.js");
    };

    NeutrinoWebview.runWeb = function () {
@@include app.js
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

    NeutrinoWebview.resolveLinuxWebKitVersion = function () {
        var importsRef = eval("imports");
        var GIRepository = importsRef["gi"]["GIRepository"];
        var Repository = GIRepository["Repository"];
        var repository = Repository["dup_default"]
            ? Repository["dup_default"]()
            : Repository["get_default"]();
        var versions = repository.enumerate_versions("WebKit2");

        if (versions.indexOf("4.1") !== -1) {
            return "4.1";
        }
        if (versions.indexOf("4.0") !== -1) {
            return "4.0";
        }
        throw this.engineUnavailable("WebKit2 introspection typelibs not found");
    };

