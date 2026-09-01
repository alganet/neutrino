    /*
     * Read through a plain GetEnvironmentVariable rather than through the
     * launcher's own scrub, which drops names in a toolkit's namespace: this
     * one is neutrino's own prefix, so it arrives intact even there.
     */
    NeutrinoWebview.webview2LibDir = function (SystemRef) {
        return SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_WEBVIEW2_LIB_DIR");
    };
