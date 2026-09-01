    /*
     * The offline overlay's answer, and the tier's whole cost: an offline app
     * cannot open a link in the user's browser. An app that wants to do that
     * wants a build without this overlay.
     */
    NeutrinoWebview.externalAllowed = function () {
        return false;
    };
