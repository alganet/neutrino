    /*
     * The Windows trace channel, which a release build does not have.
     *
     * The real one is in the testing overlay. Everything this project has
     * learned about the Windows first-window stall was read from a file it
     * writes, because from inside the app said nothing -- note() had no channel
     * on that platform at all. That is scaffolding, and scaffolding in a
     * release artifact is a file it may write beside itself for no reason
     * anybody asked for.
     */
    NeutrinoWebview.installWindowsTrace = function () {
    };
