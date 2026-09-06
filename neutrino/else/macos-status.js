    /*
     * The macOS status file, which a release build does not write.
     *
     * The real one is in the testing overlay: it reads the window's frame, its
     * content view, the screen's visible frame and the window number, and
     * writes them to a file the verifiers poll, because a screenshot cannot
     * report a frame origin. That is scaffolding, and a release artifact has no
     * business writing a file beside itself.
     */
    NeutrinoWebview.writeMacStatus = function () {
    };
