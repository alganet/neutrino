    /*
     * The document is loaded from this file, so it has no origin of its own
     * and every engine here reports it as about:blank. Anything else is a
     * navigation away from it.
     *
     * data: is deliberately not on this list. A data: document is same-null-
     * origin, so it would inherit the injected channel to the native window
     * while carrying content this file never wrote.
     */
    /*
     * A refusal that leaves no trace is indistinguishable from a window that
     * simply never came up, and those want opposite fixes. eval, because
     * JScript.NET resolves globals at compile time and has neither of these.
     *
     * This file is the launcher's half and jsc.exe compiles it, so the rule
     * still holds here. It no longer holds for an app: else/entry.js is the
     * branch jsc skips, and the README tells an author to write `window`.
     */
    /*
     * Set by a driver that has somewhere durable to write. Null everywhere
     * else, and null in every release build: the one installer is gated on
     * a testing build, which is stamped into the artifact by build.sh and
     * cannot be reached from the environment.
     */
    NeutrinoWebview.noteSink = null;

    NeutrinoWebview.note = function (message) {
        /*
         * A driver may install a sink, and on Windows one has to. A
         * /t:winexe process launched detached gets NullStream for
         * Console.Error and for both console spellings, so every line below
         * reaches nobody there -- which is why an app that stalled has
         * always "said nothing", rather than having had nothing to say.
         * recordWindowsError covers the one path that throws; a refusal,
         * and everything trace() reports, had no channel at all.
         *
         * Best effort, and deliberately not a `return`: where a caller did
         * hand this process handles, the stderr line is still worth having.
         */
        try {
            if (this.noteSink) { this.noteSink("neutrino: " + message); }
        } catch (_) {}
        /*
         * And the engine's own channel, which is else/note.js because naming
         * `printerr` or `console` is naming a global, and the compiler that
         * reads this file has neither. It used to be three eval calls here
         * for that reason. On the Windows lane there is now nothing to call:
         * that is not a channel lost, because the paragraph above is about
         * every one of those three reaching NullStream there.
         */
        try {
            if (this.noteOut) { this.noteOut("neutrino: " + message); }
        } catch (_) {}
    };



