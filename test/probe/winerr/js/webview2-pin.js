    /*
     * A pin that 404s, so the download throws the way a digest mismatch would
     * and the driver takes the real path into handleError. That is the whole
     * fixture: nothing about the driver is modified, and this artifact is the
     * output of one assemble.sh run like every other.
     *
     * `0.0.0` and not a self-describing sentinel, because this artifact goes
     * through test/build/parse.sh like the rest and parse.sh asserts the pin is
     * a version and that it appears twice in the package URL. A pin that could
     * not satisfy those would make this the one artifact exempt from the checks
     * every other one passes -- and the fixture only needs the URL to be a
     * flat-container URL for a version nuget does not have.
     *
     * The digest is the real one and is never reached: the fetch fails first.
     */
    NeutrinoWebview.webView2PinnedVersion = "0.0.0";
    NeutrinoWebview.webView2PinnedSha256 = "d3934f482d484b89fb4825df720c710664e1143a1e90f7b3a60794ef33f473d2";
