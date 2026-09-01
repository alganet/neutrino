    /*
     * No script may load or run from this document. Nothing in it is a
     * script any more -- this file's code and the author's both arrive
     * through the engine's own injection, which measurement says is exempt
     * from the policy the document carries.
     *
     * 'unsafe-eval' is there because eval is not exempt, and this file is
     * built on it: every runtime detection here goes through eval, which is
     * the documented way to keep jsc.exe from failing at compile time on
     * globals that do not exist on Windows. With script-src 'none' the
     * injected script ran and then could not identify the runtime it was
     * running in. It reads worse than it is -- eval is reachable only to
     * script that is already executing, and no script in this document can
     * begin executing: not an inline one, not a src, not a rewritten base.
     *
     * Denying the page the network is a real change to what an app can do,
     * so it is the offline tier's business and not the default's. An app
     * that fetches from its own backend is an ordinary app, not a
     * misbehaving one.
     */
    NeutrinoWebview.defaultContentPolicy = "script-src 'unsafe-eval'; object-src 'none'; " +
        "base-uri 'none'; form-action 'none'; frame-src 'none'";

    /*
     * The offline tier's policy, and what it is measured to be worth.
     *
     * It holds where it applies: an app's own page script, injected by the
     * engine, was measured reaching for the network nine ways -- fetch,
     * XMLHttpRequest, img, a stylesheet link, a script src, an iframe,
     * sendBeacon, EventSource, WebSocket -- and under this policy not one
     * of the nine reached the host on any of the four engines, while all
     * nine reached it under the policy above. So the exemption the comment
     * above describes stops at *executing*: what the exempt script then
     * loads is governed. WebView2 honours it too, from a document handed
     * over by NavigateToString.
     *
     * Two things it cannot see, because neither is a subresource load.
     *
     * The first is a url handed to the machine's browser, and that one is
     * closed -- see mayOpenExternal.
     *
     * The second is the request a top-level navigation makes on its way to
     * being refused, and that one is a **ceiling and not a fix**. Measured
     * against a loopback target that logs every request: on gjs and Qt the
     * refusal happens before the request, and nothing arrives. On macOS
     * nothing refuses at all -- PR 6 measured that implementing the policy
     * selector ships a window that never loads, so the guard is
     * -stopLoading after the document has committed -- and on the runner
     * image this was measured on, not even that: the bridge has no such
     * selector and the refusal raises, which PR 22 found in the job log
     * and filed on its own. On Windows NavigationStarting
     * cancels, the target document never runs, and the GET still reaches
     * the host. So on two of four engines an offline build leaks one
     * request per navigation attempt, with whatever the page put in the
     * url. Denying the process the network is netinstall's
     * -DNEUTRINO_CONFINE_OFFLINE, which is a different mechanism at a lower
     * layer, and the two compose.
     */
    NeutrinoWebview.offlineContentPolicy = "default-src 'none'; script-src 'unsafe-eval'; " +
        "style-src 'unsafe-inline'; img-src data:; font-src data:; " +
        "object-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'";

    NeutrinoWebview.applyContentPolicy = function (html) {
        if (!this.hasTier("offline")) {
            return html;
        }
        // Anchored on the attribute, so it cannot match this file's own
        // mention of the policy string further down the document -- the
        // whole script region is inside the document it is describing.
        var text = String(html);
        var wanted = 'content="' + this.defaultContentPolicy + '"';
        // A string replace has no failure path, and this one is the whole
        // of the offline tier: a document that does not carry the policy
        // being replaced used to come back unchanged, shipping the default
        // policy under a build that says it denies the network. The tier is
        // stamped into this file and cannot be got wrong from outside it,
        // so a build asking for it and a document that cannot take it is a
        // launcher that has no business coming up.
        if (text.indexOf(wanted) < 0) {
            throw new Error("neutrino: this build is offline and its document " +
                "does not carry the policy the tier replaces");
        }
        return text.replace(wanted, 'content="' + this.offlineContentPolicy + '"');
    };

