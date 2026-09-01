    /*
     * Where a prepared WebView2 package may be pointed at from outside, which
     * in a release build is nowhere.
     *
     * The testing overlay reads NEUTRINO_WEBVIEW2_LIB_DIR. A release build does
     * not read it, and now does not carry the read: an environment variable
     * that redirects where a process loads native assemblies from is exactly
     * the shape of thing that should not be in a shipped artifact at all,
     * rather than in it behind a flag.
     */
    NeutrinoWebview.webview2LibDir = function () {
        return null;
    };
