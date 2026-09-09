    /*
     * An export no runtime carries, so the Evergreen path cannot resolve its
     * entry point and has to fall back to the package path.
     *
     * Two substitutions and not one, because the download is no longer the
     * first thing tried: the driver renders through the runtime the machine
     * already has and only fetches when it cannot, so a build with nothing but
     * a bad pin never reaches the pin at all -- it comes up perfectly well and
     * the suite measures nothing. Naming an export that does not exist is what
     * puts the download back in front of it.
     */
    NeutrinoWebview.evergreenEntryExport = "NeutrinoNoSuchExport";
