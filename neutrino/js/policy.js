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
     * so it is the offline overlay's business and not this file's. An app
     * that fetches from its own backend is an ordinary app, not a
     * misbehaving one.
     *
     * The policy itself is html/policy.html, a part of the document like any
     * other, and the offline build includes a different one. It used to be a
     * string in here that a runtime function replaced in the loaded document,
     * which meant every launch on every lane performed a substitution to
     * arrive at a constant, and that substitution had a failure path of its
     * own -- a document that did not carry the string being replaced came
     * back unchanged, shipping the default policy under a build that said it
     * denied the network, until a check was added to throw instead. A part
     * that is included cannot come back unchanged.
     */

