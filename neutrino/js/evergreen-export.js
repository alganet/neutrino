    /*
     * The export the Evergreen runtime is entered through, which is not in any
     * header: it is the undocumented entry point the loader resolves by name
     * out of EmbeddedBrowserWebView.dll.
     *
     * A part for the same reason js/webview2-pin.js is one. An Evergreen path
     * that fails has to end up on the package path, and the only proof of it is
     * a build that gets all the way to the download -- so the winerr overlay
     * names an export that does not exist, and the resolve fails the way it
     * would on a runtime too old to carry this one.
     */
    NeutrinoWebview.evergreenEntryExport = "CreateWebViewEnvironmentWithOptionsInternal";
