    /*
     * Where the Windows driver may be told to find the artifact, which in a
     * release build is nowhere: it finds its own path and nothing may say
     * otherwise.
     *
     * The testing overlay reads NEUTRINO_SCRIPT_PATH, because a suite that
     * launches an app from a staging directory has to be able to say where the
     * file is. That is a reason to build with the overlay, not a reason for
     * every shipped app to honour an environment variable naming the file it
     * will read itself.
     */
    NeutrinoWebview.scriptPathOverride = function () {
        return null;
    };
