    /*
     * This overlay exists for one suite and one reason: to keep it hermetic.
     *
     * verify-nav.ps1 measures whether a refused navigation still reached the
     * network, using a request log as its instrument. Since window.open was
     * given its standard meaning, an external url handed to it -- or to a new
     * window the guard refuses -- is forwarded to the machine's browser, which
     * is the correct behaviour and ruinous here: the browser would fetch the
     * very url the instrument is a log for, and every refusal assertion in the
     * suite would be answering a question about a browser.
     *
     * It used to come from neutrino/tier/offline, which supplied this file and
     * a denying content policy together. The tiers are gone, so the suite
     * carries the one part it actually needed -- which is also the shape an app
     * author uses now: an ordinary --overlay replacing an ordinary part.
     */
    NeutrinoWebview.externalAllowed = function () {
        return false;
    };
