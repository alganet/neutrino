    /*
     * A note worth making in a release build is a refusal or a failure.
     * Anything that is only interesting while working out why a lane is red is
     * a trace, and a release build does not make one -- this is the whole of
     * what it does here.
     *
     * It used to be `if (this.hasTier("testing")) this.note(message);`, so a
     * release artifact carried the branch, the stamp it read, and every call
     * site's message. The testing overlay replaces this file with one that
     * notes; nothing else in the tree changes, because every caller already
     * spells it `this.trace(...)`.
     */
    NeutrinoWebview.trace = function () {
    };
