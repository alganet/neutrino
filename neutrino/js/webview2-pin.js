    /*
     * The WebView2 package this build fetches when the machine has no runtime
     * of its own, and what the archive has to hash to.
     *
     * Both in one part, because they are one statement about one package: a
     * file that could carry the version without the digest is a file that can
     * disagree with itself, and the digest is the only thing standing between
     * a 45 MB download and the assemblies this app loads into its own process.
     *
     * It is a part rather than two lines in webview2.js because a suite has to
     * be able to say "fetch something that is not there" -- the windows-launch
     * lane provokes a failed initialisation by pinning a version that 404s, so
     * the download throws the way a digest mismatch would and the driver takes
     * the real path into handleError. That used to be two `sed -i` calls over
     * the assembled artifact, with a `grep -q` after each to say whether they
     * had landed. See test/probe/winerr/, which replaces this file instead.
     */
    NeutrinoWebview.webView2PinnedVersion = "1.0.4129.50";
    NeutrinoWebview.webView2PinnedSha256 = "d3934f482d484b89fb4825df720c710664e1143a1e90f7b3a60794ef33f473d2";
