    /*
     * The Windows driver's own account, on disk, in a testing build.
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
