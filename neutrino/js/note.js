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
     * JScript.NET resolves globals at compile time and has neither of these
     * -- the same reason the README gives for eval("window").
     */
    /*
     * Set by a driver that has somewhere durable to write. Null everywhere
     * else, and null in every release build: the one installer is gated on
     * the testing tier, which is stamped into the artifact by build.sh and
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
        try {
            eval("printerr")("neutrino: " + message);
            return;
        } catch (_) {}
        try {
            eval("console").warn("neutrino: " + message);
            return;
        } catch (_) {}
        try {
            eval("console").log("neutrino: " + message);
        } catch (_) {}
    };

    /*
     * The Windows driver's own account, on disk, under the testing tier.
     *
     * Everything this file has ever learned about the Windows first-window
     * stall was read from outside, because from inside the app said nothing
     * -- not for want of lines, but because note() had no channel on this
     * platform at all. This gives it one, timestamped from the moment the
     * driver started, so "the title was set and not seen" and "the title
     * was never set" stop being the same reading.
     *
     * The file is truncated at install: a stale trace from an earlier
     * launch answering questions about this one is the same defect PR 7
     * fixed for the seatbelt profile.
     */
    NeutrinoWebview.installWindowsTrace = function (SystemRef, appFolder) {
        var path = SystemRef.IO.Path.Combine(appFolder, "neutrino-trace.log");
        var started = SystemRef.DateTime.UtcNow;
        try {
            SystemRef.IO.File.WriteAllText(path, "");
        } catch (_) {
            return;
        }
        this.noteSink = function (message) {
            try {
                var ms = Math.round(
                    SystemRef.DateTime.UtcNow.Subtract(started).TotalMilliseconds);
                SystemRef.IO.File.AppendAllText(path, ms + "ms " + message + "\r\n");
            } catch (_) {}
        };
    };

    /*
     * A note worth making in a release build is a refusal or a failure.
     * Anything that is only interesting while working out why a lane is red
     * belongs here instead, where a release build never says it.
     */
    NeutrinoWebview.trace = function (message) {
        if (this.hasTier("testing")) {
            this.note(message);
        }
    };

