    /*
     * No script may load or run from this document, and that is now the whole
     * of what it says. Nothing in it is a script -- this file's code and the
     * author's both arrive through the engine's own injection, which
     * measurement says is exempt from the policy the document carries.
     *
     * It used to be `script-src 'unsafe-eval'`, and the reason was a single
     * function. eval is not exempt, and the dispatch that decides which engine
     * is running was five eval calls -- the documented way to keep jsc.exe
     * from failing at compile time on globals no Windows machine has. The page
     * ran that dispatch on load, so with 'none' the injected script started
     * and could not work out where it was.
     *
     * There is nothing left to ask. Which engine is running is decided by
     * which branch of the conditional-compilation block the program was built
     * from, so jsc/dispatch.jsc answers it for the Windows launcher and
     * else/engine.js for everyone else, in the plain spelling, with no eval on
     * any path a page reaches. The same move took the three eval calls out of
     * note(). See js/run.js.
     *
     * What this costs an app is real and is worth saying: `eval` and `new
     * Function` no longer run in this document, on any lane. An app that wants
     * them writes its own html/policy.html, which is an overlay part like any
     * other.
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

