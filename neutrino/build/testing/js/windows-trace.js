    /*
     * The Windows driver's own account, on disk, in a testing build.
     *
     * Everything this file has ever learned about the Windows first-window
     * stall was read from a file it writes, because from inside the app said
     * nothing -- not for want of lines, but because note() had no channel on
     * this platform at all. This gives it one, timestamped from the moment the
     * driver started, so "the title was set and not seen" and "the title
     * was never set" stop being the same reading.
     *
     * The file is truncated at install: a stale trace from an earlier
     * launch answering questions about this one is the same defect PR 7
     * fixed for the seatbelt profile.
     */
    NeutrinoWebview.installWindowsTrace = function (SystemRef, appFolder) {
        var path = SystemRef.IO.Path.Combine(appFolder, "neutrino-trace.log");
        try {
            SystemRef.IO.File.WriteAllText(path, "");
        } catch (_) {
            return;
        }
        /*
         * And what happened before any of it, which is the one phase of a
         * launch this trace has never been able to see.
         *
         * Zero below is the driver's first line, not the launch's: by the time
         * it is written cmd.exe has run the batch region, the CLR has started,
         * mscorlib, System, System.Drawing, System.Windows.Forms and the
         * JScript runtime have loaded, and this program's global code has run.
         * A trace that starts at zero reports all of that as free, and every
         * number this project has quoted for a Windows launch -- 789ms to the
         * title on a runner -- is the part after it. Process.StartTime is when
         * the kernel made this process, so the difference is exactly the .NET
         * half of that prefix. The batch half happens in another process
         * before this one exists; test/launchtime.ps1 reads it from outside.
         *
         * Asked before the clock rather than after it, and the asking is
         * reported separately, because it is not free: the first touch of
         * System.Diagnostics in this process was measured at 38ms on a runner,
         * which is five times what init costs. Charged to `started` it would
         * move every line under it by that much and the trace would be
         * describing itself -- init landed at 44ms where it has always landed
         * at 6ms, on the first run of this file. So the timeline begins after
         * the instrument has paid for itself, the prefix is the launch's own,
         * and the second number is what asking for the first one cost.
         *
         * None of it exists in a release build, where installWindowsTrace is
         * an empty function -- see js/windows-trace.js.
         */
        var asked = SystemRef.DateTime.UtcNow;
        var before = null;
        var reached = null;
        var processStart = null;
        try {
            processStart = SystemRef.Diagnostics.Process.GetCurrentProcess()
                .StartTime.ToUniversalTime();
            before = Math.round(asked.Subtract(processStart).TotalMilliseconds);
        } catch (_) {
        }
        // Separately, because a boxed DateTime reached through late binding is
        // one more thing that can throw, and it must not take the reading above
        // down with it. See build/testing/js/trace.js for where the mark is set.
        try {
            if (processStart !== null && this.traceLoadedAt) {
                reached = Math.round(
                    this.traceLoadedAt.Subtract(processStart).TotalMilliseconds);
            }
        } catch (_) {
        }
        var started = SystemRef.DateTime.UtcNow;
        var self = this;
        var measured = false;
        this.noteSink = function (message) {
            try {
                var ms = Math.round(
                    SystemRef.DateTime.UtcNow.Subtract(started).TotalMilliseconds);
                SystemRef.IO.File.AppendAllText(path, ms + "ms " + message + "\r\n");
            } catch (_) {}
            /*
             * And then, once, the machine.
             *
             * test/launchtime.ps1 asks these questions from outside, which
             * needs a shell, a checkout and a way to run one -- and the
             * machine whose launch is slow is not always a machine anyone can
             * conveniently do that on. Everything below is answerable from
             * inside the app, so a person with a slow launch can double click
             * one artifact and send the log next to it.
             *
             * Hung off the sink rather than called from the driver, so a
             * release build changes by not one byte: there is no call site to
             * compile out, no flag to read, and js/windows-trace.js stays the
             * empty function it is. The trigger is the first title, which is
             * the moment the app is up -- these spawn processes, and six
             * process starts during a launch would corrupt the numbers the
             * launch is being measured for. An app that never sets a title
             * never measures, which is the right trade for scaffolding.
             */
            if (!measured && String(message).indexOf("title -> ") >= 0) {
                measured = true;
                try { self.measureWindowsMachine(SystemRef); } catch (_) {}
            }
        };
        if (before !== null) {
            this.trace("start: " + before +
                "ms of this process before its first line, plus " +
                Math.round(started.Subtract(asked).TotalMilliseconds) +
                "ms to ask");
            if (reached !== null) {
                this.trace("start: " + reached +
                    "ms of that reached js/trace.js -- the CLR, the JScript " +
                    "runtime and fourteen parts -- and " + (before - reached) +
                    "ms went from there to here, which is the rest of the " +
                    "global code, the toolkit and init");
            }
        }
    };

    /*
     * What this machine is, and what it charges for a process.
     *
     * The launch this trace measures creates four processes -- cmd.exe, the
     * nested cmd `FOR /F usebackq` hands the backticked command to, certutil,
     * and the exe -- and two of the four exist only to hash the script. On a
     * runner one process start is ten milliseconds and that is not worth an
     * argument. On a client machine with a scanner in front of every
     * CreateProcess it is a different number, and the difference between a
     * server SKU and a desktop one is the first thing to suspect when the same
     * app takes 934ms on one and seconds on the other.
     *
     * So this asks it twice over. The registry values say what is configured;
     * the two timings say what it costs, which is the reading that matters and
     * the one that cannot be argued with. A configuration that looks quiet and
     * a process start that costs two hundred milliseconds is still two hundred
     * milliseconds.
     *
     * Absent registry values are reported as absent rather than defaulted.
     * Every one of these has a meaning when missing -- Windows' own default --
     * and a probe that silently substitutes it is a probe that cannot tell a
     * machine with the setting off from a machine that never had it.
     *
     * Two things a reader should not mistake for regressions. This starts
     * programs, which the driver is not allowed to do by name -- so both are
     * absolute paths under %WINDIR%\System32, built here rather than searched
     * for. And it sets UseShellExecute to false, which test/winexec.ps1 fails
     * the artifact for carrying: that control reads a release build, and none
     * of this is in one.
     *
     * It runs on the UI thread and the window is unresponsive while it does.
     * That is half a second after the app is already up, in a build that also
     * writes a log file beside itself.
     */
    NeutrinoWebview.measureWindowsMachine = function (SystemRef) {
        var self = this;
        var registry = SystemRef.Type.GetType("Microsoft.Win32.Registry");
        var getValue = registry ? registry.GetMethod("GetValue") : null;
        var read = function (key, name) {
            if (!getValue) {
                return null;
            }
            try {
                return getValue.Invoke(null, [key, name, null]);
            } catch (_) {
                return null;
            }
        };
        var say = function (label, key, name) {
            var value = read(key, name);
            self.trace("machine: " + label + "=" +
                (value === null || value === undefined ? "absent" : String(value)));
        };

        var nt = "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
        say("product", nt, "ProductName");
        say("build", nt, "CurrentBuild");
        say("edition", nt, "EditionID");
        say("installtype", nt, "InstallationType");
        say("smartscreen",
            "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer",
            "SmartScreenEnabled");
        say("defender.antispyware",
            "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows Defender",
            "DisableAntiSpyware");
        say("defender.realtime",
            "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows Defender\\" +
                "Real-Time Protection",
            "DisableRealtimeMonitoring");

        var script = null;
        try {
            script = String(this.windowsLayout(SystemRef).script);
        } catch (_) {
        }
        if (script) {
            /*
             * Mark of the web, asked of the zone manager rather than of the
             * stream. `path:Zone.Identifier` is a valid thing to open and not
             * a valid thing to hand .NET Framework's path validation, which
             * rejects the second colon before any file is touched -- so a
             * probe written that way answers "no mark" on every machine,
             * including the ones that have one. Zone.CreateFromUrl goes
             * through MapUrlToZone, which is what reads the stream and is
             * also what SmartScreen's own decision is made from.
             *
             * `Internet` here is a downloaded file. `MyComputer` is a file
             * that arrived some other way, and a machine that strips the mark
             * reads the same -- so this can say yes with certainty and no only
             * with a shrug.
             */
            try {
                self.trace("machine: zone=" + String(
                    SystemRef.Security.Policy.Zone.CreateFromUrl(
                        "file:///" + script.split("\\").join("/")).SecurityZone));
            } catch (_) {
                self.trace("machine: zone could not be read");
            }
        }

        var windir = SystemRef.Environment.GetEnvironmentVariable("WINDIR");
        if (!windir) {
            self.trace("machine: no WINDIR, so nothing was timed");
            return;
        }
        var system32 = SystemRef.IO.Path.Combine(String(windir), "System32");
        var best = function (exe, args) {
            if (!SystemRef.IO.File.Exists(exe)) {
                return -1;
            }
            var lowest = -1;
            for (var i = 0; i < 3; i++) {
                var t0 = SystemRef.DateTime.UtcNow;
                try {
                    var info = new SystemRef.Diagnostics.ProcessStartInfo(exe, args);
                    info.UseShellExecute = false;
                    info.CreateNoWindow = true;
                    SystemRef.Diagnostics.Process.Start(info).WaitForExit();
                } catch (_) {
                    return -1;
                }
                var ms = Math.round(
                    SystemRef.DateTime.UtcNow.Subtract(t0).TotalMilliseconds);
                if (lowest < 0 || ms < lowest) {
                    lowest = ms;
                }
            }
            return lowest;
        };

        var floor = best(SystemRef.IO.Path.Combine(system32, "cmd.exe"), "/c exit");
        self.trace("machine: one process start costs " + floor +
            "ms here, best of 3, and a launch pays for four");
        if (script) {
            var hash = best(SystemRef.IO.Path.Combine(system32, "certutil.exe"),
                "-hashfile \"" + script + "\" SHA256");
            self.trace("machine: the stamp's hash costs " + hash +
                "ms, and the launcher pays that plus a nested cmd every launch");
        }
    };
