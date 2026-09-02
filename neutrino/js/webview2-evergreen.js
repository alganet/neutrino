    /*
     * Finding the WebView2 that is already on the machine, and starting an
     * environment against it without downloading anything.
     *
     * The package path this sits beside is unchanged and stays: everything
     * here answers null when it cannot proceed, and a null is the launcher
     * fetching the SDK exactly as it does today. That is the whole safety
     * argument for the section below, because one thing in it is not a
     * supported API.
     */

    /*
     * Which version is installed, asked of EdgeUpdate.
     *
     * Not by client id. This started as a probe for a GUID copied out of
     * Microsoft's own detection sample, and the GUID was wrong in its last two
     * groups -- so it reported no runtime on a machine whose install directory
     * was sitting there, and did it twice before the keys were enumerated and
     * the mistake became visible. A GUID that has to be right is a constant
     * with no failure path: wrong, it reads exactly like absent.
     *
     * The display name is the reading instead. Every client under EdgeUpdate is
     * walked and the one that says it is the WebView2 Runtime is the answer,
     * which is a string that can be checked against the machine rather than
     * against a document. Beta, Dev and Canary carry their channel in the same
     * name and are refused, because a preview runtime is not what an app should
     * silently be rendered by.
     *
     * Three roots because there are three ways it installs: machine-wide on a
     * 64-bit OS -- under WOW6432Node, EdgeUpdate being a 32-bit component --
     * machine-wide on a 32-bit OS, and per-user.
     */
    NeutrinoWebview.evergreenRuntimeVersion = function (SystemRef) {
        var registry = SystemRef.Type.GetType("Microsoft.Win32.Registry");
        if (!registry) {
            return null;
        }
        var roots = [
            ["LocalMachine", "SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients"],
            ["LocalMachine", "SOFTWARE\\Microsoft\\EdgeUpdate\\Clients"],
            ["CurrentUser", "SOFTWARE\\Microsoft\\EdgeUpdate\\Clients"]
        ];
        for (var i = 0; i < roots.length; i++) {
            try {
                // A field and not a property. Registry.LocalMachine is
                // `public static readonly RegistryKey`, so GetProperty answers
                // null here and the whole walk would come back empty on a
                // machine that has everything.
                var hiveField = registry.GetField(roots[i][0]);
                if (!hiveField) {
                    continue;
                }
                var hive = hiveField.GetValue(null);
                if (!hive) {
                    continue;
                }
                var clients = hive.OpenSubKey(roots[i][1]);
                if (!clients) {
                    continue;
                }
                var names = clients.GetSubKeyNames();
                for (var j = 0; j < names.Length; j++) {
                    var client = clients.OpenSubKey(names[j]);
                    if (!client) {
                        continue;
                    }
                    var label = String(client.GetValue("name") || "");
                    var version = String(client.GetValue("pv") || "");
                    if (label.indexOf("WebView2") < 0) {
                        continue;
                    }
                    if (/Beta|Dev|Canary/.test(label)) {
                        continue;
                    }
                    // Written but not installed is what this reads as, and it
                    // is not the same as the value being absent.
                    if (version === "" || version === "0.0.0.0") {
                        continue;
                    }
                    return version;
                }
            } catch (_) {
            }
        }
        return null;
    };

    /*
     * Where that version lives. The path is a convention rather than something
     * the registry hands over, so it is searched for and the name is checked:
     * the Application directory holds bookkeeping folders -- PlatformExperiences
     * Helper, SetupMetrics -- beside the versioned one, and a walk that takes
     * whatever it finds last takes one of those. Only a name that is a version
     * is a candidate, and the one the registry named wins over any other.
     */
    NeutrinoWebview.evergreenRuntimeDir = function (SystemRef, version) {
        var roots = [
            SystemRef.Environment.GetEnvironmentVariable("ProgramFiles(x86)"),
            SystemRef.Environment.GetEnvironmentVariable("ProgramFiles"),
            SystemRef.Environment.GetEnvironmentVariable("LOCALAPPDATA")
        ];
        var fallback = null;
        for (var i = 0; i < roots.length; i++) {
            if (!roots[i]) {
                continue;
            }
            var base = SystemRef.IO.Path.Combine(String(roots[i]),
                "Microsoft\\EdgeWebView\\Application");
            if (!SystemRef.IO.Directory.Exists(base)) {
                continue;
            }
            var wanted = SystemRef.IO.Path.Combine(base, version);
            if (version && SystemRef.IO.Directory.Exists(wanted)) {
                return wanted;
            }
            var dirs = SystemRef.IO.Directory.GetDirectories(base);
            for (var j = 0; j < dirs.Length; j++) {
                var leaf = String(SystemRef.IO.Path.GetFileName(dirs[j]));
                if (/^[0-9]+(\.[0-9]+)+$/.test(leaf) && !fallback) {
                    fallback = dirs[j];
                }
            }
        }
        return fallback;
    };

    /*
     * The entry point, and the one part of this design that is not supported.
     *
     * The runtime does not ship WebView2Loader.dll -- that is an SDK component,
     * and it is the only piece the package carries that the runtime does not.
     * What the runtime has is the library the loader would have loaded, and the
     * export the loader would have called through:
     * CreateWebViewEnvironmentWithOptionsInternal, one of eight exports in
     * EBWebView\<arch>\EmbeddedBrowserWebView.dll.
     *
     * Nothing promises that name or that signature across runtime versions. It
     * is depended on here because the alternative is carrying a 150 KB binary
     * per architecture inside a text artifact, and because the cost of being
     * wrong is bounded: every failure below returns null, and null is the
     * package download this launcher already does. A runtime that stops
     * answering makes an app slower on first run, not broken.
     *
     * By process bitness, not by machine: a 32-bit process cannot load the
     * x64 library, and which one this is depends on how the exe was built
     * rather than on what the OS is.
     */
    NeutrinoWebview.evergreenEntryDll = function (SystemRef, runtimeDir) {
        if (!runtimeDir) {
            return null;
        }
        var arch = SystemRef.Environment.Is64BitProcess ? "x64" : "x86";
        var dll = SystemRef.IO.Path.Combine(runtimeDir,
            SystemRef.IO.Path.Combine("EBWebView", SystemRef.IO.Path.Combine(arch,
                "EmbeddedBrowserWebView.dll")));
        return SystemRef.IO.File.Exists(dll) ? dll : null;
    };

    NeutrinoWebview.evergreenEntryExport = "CreateWebViewEnvironmentWithOptionsInternal";

    /*
     * Every interface in the table, built once. The slot numbers are the data
     * and this is only the walk: see js/webview2-interfaces.js for where they
     * come from and why a wrong one has no reading of its own.
     *
     * The three argument interfaces are handed to the callback side afterwards,
     * because a handler has to call back into the object it was given and a
     * JScript.NET class cannot reach a JScript global to find out how.
     */
    NeutrinoWebview.buildEvergreenTypes = function () {
        var built = {};
        for (var key in this.webView2Interfaces) {
            if (!this.webView2Interfaces.hasOwnProperty(key)) {
                continue;
            }
            var spec = this.webView2Interfaces[key];
            NeutrinoEvergreen.DefineInterface("Neutrino_" + key, spec.iid);
            for (var name in spec.calls) {
                if (!spec.calls.hasOwnProperty(name)) {
                    continue;
                }
                var call = spec.calls[name];
                NeutrinoEvergreen.DefineSlot(call[0], name, call[1], call[2]);
            }
            built[key] = NeutrinoEvergreen.EndInterface();
        }
        NeutrinoEvergreen.messageArgsType = built.messageArgs;
        NeutrinoEvergreen.navigationArgsType = built.navigationArgs;
        NeutrinoEvergreen.newWindowArgsType = built.newWindowArgs;
        return built;
    };

    /*
     * Pumping, which every step of this needs and none of them can do without.
     * The completion handlers are posted to this thread, so a wait that does
     * not run the message loop is a wait that never ends.
     *
     * Bounded, and the bound is reported rather than thrown: a runtime that
     * does not answer is the package path's cue, and an exception here would
     * take the launch down instead of falling back.
     */
    NeutrinoWebview.pumpUntil = function (SystemRef, ready, milliseconds) {
        var spins = Math.floor(milliseconds / 16);
        for (var i = 0; i < spins; i++) {
            if (ready()) {
                return true;
            }
            SystemRef.Windows.Forms.Application.DoEvents();
            SystemRef.Threading.Thread.Sleep(16);
        }
        return ready();
    };

    /*
     * The environment, which is the first thing that can fail for a reason
     * worth telling apart. Answers null on every one of them, having said which.
     */
    NeutrinoWebview.startEvergreen = function (SystemRef, userDataDir) {
        var version = this.evergreenRuntimeVersion(SystemRef);
        var runtimeDir = this.evergreenRuntimeDir(SystemRef, version);
        if (!runtimeDir) {
            this.trace("evergreen: no installed runtime found");
            return null;
        }
        var dll = this.evergreenEntryDll(SystemRef, runtimeDir);
        if (!dll) {
            this.trace("evergreen: no entry library under " + runtimeDir);
            return null;
        }
        this.trace("evergreen: runtime " + (version ? version : "unversioned") +
            " at " + runtimeDir);

        if (!NeutrinoEvergreen.Begin()) {
            this.trace("evergreen: the emitter would not start");
            return null;
        }
        var types = this.buildEvergreenTypes();
        if (!NeutrinoEvergreen.DefineEntry(
                SystemRef.IO.Path.GetFileName(dll), this.evergreenEntryExport)) {
            return null;
        }
        // The library goes in by full path first, so the stub that names it
        // resolves against the module this chose rather than against whatever
        // the loader search order would have found.
        if (!NeutrinoEvergreen.LoadModule(dll)) {
            this.trace("evergreen: " + dll + " would not load");
            return null;
        }

        var handler = NeutrinoEvergreen.MakeSink("NeutrinoEnvSink",
            this.webView2Handlers.environmentCompleted.iid,
            this.webView2Handlers.environmentCompleted.args,
            this.webView2Handlers.environmentCompleted.target);

        var hr = NeutrinoEvergreen.CreateEnvironment(userDataDir, handler);
        if (hr !== 0) {
            this.trace("evergreen: the entry point answered " + hr);
            return null;
        }
        var self = this;
        this.pumpUntil(SystemRef, function () {
            return NeutrinoEvergreen.environmentDone;
        }, 60000);
        if (!NeutrinoEvergreen.environmentDone) {
            this.trace("evergreen: the runtime never called back");
            return null;
        }
        if (NeutrinoEvergreen.environmentHr !== 0 ||
                String(NeutrinoEvergreen.environmentPtr) === "0") {
            this.trace("evergreen: the environment failed with " +
                NeutrinoEvergreen.environmentHr);
            return null;
        }

        var environment = NeutrinoEvergreen.Wrap(
            NeutrinoEvergreen.environmentPtr, types.environment);
        // Asked because it is the cheapest proof that the vtable is the one
        // this build thinks it is: a wrong slot answers S_OK with nothing
        // behind it, and this is the slot that would say so.
        var reported = NeutrinoEvergreen.TakeString(
            types.environment.GetMethod("get_BrowserVersionString").Invoke(environment, null));
        if (!reported) {
            this.trace("evergreen: the environment would not name a version");
            return null;
        }
        this.trace("evergreen: environment up, runtime says " + reported);
        return { types: types, environment: environment, version: String(reported) };
    };
