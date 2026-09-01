    /*
     * Whether a url this launcher agrees is external may be handed to the
     * machine's browser.
     *
     * A whole file for one `return`, and that is the point: it is the part the
     * offline overlay replaces. It used to be `!this.hasTier("offline")`, which
     * meant a build that denied the page the network still carried the code to
     * open a browser and a stamp saying not to use it. What ships now is the
     * answer, and an offline build has no other one in it.
     *
     * The route this closes is the one no content policy can see: a policy
     * governs what the *document* may fetch, and handing a url to the desktop
     * is another program making the request. See mayOpenExternal, which is
     * where every driver's end-of-the-line check now asks.
     */
    NeutrinoWebview.externalAllowed = function () {
        return true;
    };
