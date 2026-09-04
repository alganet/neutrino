    NeutrinoWebview.hasWebView2Assemblies = function (SystemRef, libDir) {
        if (!libDir) {
            return false;
        }
        return SystemRef.IO.File.Exists(SystemRef.IO.Path.Combine(libDir, "Microsoft.Web.WebView2.Core.dll")) &&
            SystemRef.IO.File.Exists(SystemRef.IO.Path.Combine(libDir, "Microsoft.Web.WebView2.WinForms.dll"));
    };

    NeutrinoWebview.windowsLayoutCache = null;

    /*
     * Where this program is, and therefore where everything else is. One
     * rule, answered once, because the document's path and the app folder
     * used to be decided by two different mechanisms that only agreed by
     * accident: the document came from an environment variable the launcher
     * set, and the app folder from Application.StartupPath. Moving the exe
     * out of the app folder broke the second and would have left the first
     * pointing somewhere the exe no longer lives.
     *
     * The batch region compiles to <dir>\<name>.exe beside the script and
     * keeps it, and falls back to <dir>\<name>\<name>.exe when the script's
     * own directory will not take a file. Both layouts name the same app
     * folder, <dir>\<name>, and in both the script is <name>.cmd -- beside
     * the exe in the first, one level above it in the second. So the exe
     * looks beside itself first and above itself second, and what it finds
     * decides which of the two it is in.
     *
     * Two extensions, because %~n0 has already dropped the real one by the
     * time the batch region names anything: netinstall always writes .cmd,
     * cmd.exe will run a .bat as readily, and it will run nothing else.
     */
    NeutrinoWebview.windowsLayout = function (SystemRef) {
        if (this.windowsLayoutCache) {
            return this.windowsLayoutCache;
        }
        var exe = SystemRef.Windows.Forms.Application.ExecutablePath;
        var name = SystemRef.IO.Path.GetFileNameWithoutExtension(exe);
        var exeDir = SystemRef.IO.Path.GetDirectoryName(exe);
        if (exeDir == null || String(exeDir) === "" ||
                name == null || String(name) === "") {
            throw new Error("neutrino: this program is not where a neutrino " +
                "launcher puts it (" + String(exe) + ")");
        }

        var beside = this.windowsScriptIn(SystemRef, exeDir, name);
        if (beside != null) {
            this.windowsLayoutCache = {
                script: beside,
                appFolder: SystemRef.IO.Path.Combine(exeDir, name)
            };
            return this.windowsLayoutCache;
        }

        // GetDirectoryName answers null at a volume root, and Path.Combine
        // throws on a null rather than returning one.
        var parent = SystemRef.IO.Path.GetDirectoryName(exeDir);
        if (parent != null && String(parent) !== "") {
            var above = this.windowsScriptIn(SystemRef, parent, name);
            if (above != null) {
                this.windowsLayoutCache = { script: above, appFolder: exeDir };
                return this.windowsLayoutCache;
            }
        }

        throw new Error("neutrino: could not find the document this program " +
            "was compiled from; looked for " + name + ".cmd and " + name +
            ".bat beside it in " + exeDir + " and one level above");
    };

    NeutrinoWebview.windowsScriptIn = function (SystemRef, dir, name) {
        var asCmd = SystemRef.IO.Path.Combine(dir, name + ".cmd");
        if (SystemRef.IO.File.Exists(asCmd)) {
            return asCmd;
        }
        var asBat = SystemRef.IO.Path.Combine(dir, name + ".bat");
        if (SystemRef.IO.File.Exists(asBat)) {
            return asBat;
        }
        return null;
    };

    NeutrinoWebview.findWebView2LibDir = function (SystemRef, appFolder) {
        /*
         * This is an environment variable that ends at Assembly.LoadFrom,
         * so anything able to set it chooses which code this process loads.
         * netinstall's environment allowlist keeps the whole NEUTRINO_
         * prefix, so it arrives intact even there. A release build does not
         * read it and does not carry the read: the tests that need to point at
         * a prepared package build with the testing overlay.
         */
        var envLibDir = this.webview2LibDir(SystemRef);
        if (this.hasWebView2Assemblies(SystemRef, envLibDir)) {
            return envLibDir;
        }

        var directNet462 = SystemRef.IO.Path.Combine(appFolder, "Microsoft.Web.WebView2", "lib", "net462");
        if (this.hasWebView2Assemblies(SystemRef, directNet462)) {
            return directNet462;
        }

        var directNet45 = SystemRef.IO.Path.Combine(appFolder, "Microsoft.Web.WebView2", "lib", "net45");
        if (this.hasWebView2Assemblies(SystemRef, directNet45)) {
            return directNet45;
        }

        if (SystemRef.IO.Directory.Exists(appFolder)) {
            var packageDirs = SystemRef.IO.Directory.GetDirectories(appFolder, "Microsoft.Web.WebView2*");
            for (var i = 0; i < packageDirs.Length; i++) {
                var candidateNet462 = SystemRef.IO.Path.Combine(packageDirs[i], "lib", "net462");
                if (this.hasWebView2Assemblies(SystemRef, candidateNet462)) {
                    return candidateNet462;
                }

                var candidateNet45 = SystemRef.IO.Path.Combine(packageDirs[i], "lib", "net45");
                if (this.hasWebView2Assemblies(SystemRef, candidateNet45)) {
                    return candidateNet45;
                }
            }
        }

        return null;
    };

    NeutrinoWebview.prependLoaderPaths = function (SystemRef, webView2LibDir) {
        if (!webView2LibDir) {
            return;
        }

        var packageRoot = this.webView2PackageRootOf(SystemRef, webView2LibDir);
        var loaderPaths = "";

        var x86Loader = SystemRef.IO.Path.Combine(packageRoot, "runtimes", "win-x86", "native", "WebView2Loader.dll");
        if (SystemRef.IO.File.Exists(x86Loader)) {
            loaderPaths = SystemRef.IO.Path.GetDirectoryName(x86Loader) + ";" + loaderPaths;
        }

        var x64Loader = SystemRef.IO.Path.Combine(packageRoot, "runtimes", "win-x64", "native", "WebView2Loader.dll");
        if (SystemRef.IO.File.Exists(x64Loader)) {
            loaderPaths = SystemRef.IO.Path.GetDirectoryName(x64Loader) + ";" + loaderPaths;
        }

        var arm64Loader = SystemRef.IO.Path.Combine(packageRoot, "runtimes", "win-arm64", "native", "WebView2Loader.dll");
        if (SystemRef.IO.File.Exists(arm64Loader)) {
            loaderPaths = SystemRef.IO.Path.GetDirectoryName(arm64Loader) + ";" + loaderPaths;
        }

        if (loaderPaths) {
            var currentPath = SystemRef.Environment.GetEnvironmentVariable("PATH");
            if (!currentPath) {
                currentPath = "";
            }
            SystemRef.Environment.SetEnvironmentVariable("PATH", loaderPaths + currentPath);
        }
    };


    /*
     * The package this build was made against, named by version and by the
     * digest of the archive that version resolves to. Both are checked --
     * the version alone only says which name was asked for, and a name is
     * not what gets loaded.
     *
     * netinstall names every artifact it fetches by SHA-256 and re-checks
     * it on every launch. This fetch used to be "whatever nuget.org serves
     * today", which made the one directory the launcher loads code from the
     * only thing in the chain nobody was verifying.
     *
     * Bumping this means changing the version, the archive digest and every
     * member digest together. They are asserted against each other, so
     * changing one alone fails the build's own suite rather than silently
     * accepting a package nobody looked at.
     */
    /*
     * What the browser is started with, and this is a control rather than a
     * speed-up -- which is not what it was written to be.
     *
     * It went in for startup: the controller is around four hundred
     * milliseconds of an eight hundred millisecond launch, nearly all of it a
     * browser starting, and WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS is the cheap
     * way to hand that browser switches. Measured on the windows lane, off the
     * process table rather than off a clock: `browser processes=6 carrying our
     * arguments=0`. The variable is read by WebView2Loader.dll, and the
     * Evergreen path does not use the loader -- it calls the runtime's own
     * entry point. So on the path this build usually takes, these switches
     * never arrive, and nothing here makes the browser faster.
     *
     * What survives is the reason it is written unconditionally. The package
     * path *does* go through the loader, so there the variable is live -- and
     * live for anyone who can set it, not only for this file.
     * `--disable-web-security` and `--remote-debugging-port` are switches on
     * the browser rendering the app, arriving from the environment.
     * netinstall's allowlist has no WEBVIEW2_ name and no prefix admitting one,
     * so it never gets there; standalone on Windows nothing scrubbed it and
     * nothing overwrote it. Writing it here is what closes that, on the one
     * path where it can be closed, and writing it on both paths costs a
     * SetEnvironmentVariable.
     *
     * The switches themselves stay chosen for the startup they were meant to
     * save, because that is what they should be if the options object ever
     * carries them instead. None touches what the page may do: no sandbox
     * switch, no SmartScreen switch, nothing about web security. A view
     * rendering a local document is still a browser and is still treated as
     * one.
     *
     * Making them reach the Evergreen path means ICoreWebView2EnvironmentOptions
     * -- an emitted class the runtime queries eight methods on, where
     * everything emitted here today is an interface with no bodies at all.
     * Worth knowing before writing one: that is what this measurement bought.
     */
    NeutrinoWebview.webView2BrowserArguments =
        "--no-first-run --disable-background-networking " +
        "--disable-component-update --disable-sync --no-pings";

    NeutrinoWebview.webView2PinnedVersion = "1.0.4129.50";
    NeutrinoWebview.webView2PinnedSha256 = "d3934f482d484b89fb4825df720c710664e1143a1e90f7b3a60794ef33f473d2";

    /*
     * Exactly what is taken out of the archive, and what each one has to
     * hash to. The package is ~45 MB unpacked and almost all of it is
     * native build headers and import libs for C++ hosts; these are the
     * managed assemblies and the loaders, which is everything this app ever
     * touches.
     *
     * This list replaces a regular expression, and that is the fix for the
     * zip-slip rather than a better regular expression. The old form built
     * a destination out of the name the archive supplied -- and `[^/]+`
     * admits backslashes, so `lib/net462/..\..\..\..\x.dll` matched the
     * pattern and named a file four directories above the one being
     * extracted into. Measured, twice: it wrote out of the package
     * directory and into the user's profile directory. Now the extractor
     * asks the archive for names it already holds, and the name that
     * becomes a path is one of these literals. There is no attacker-shaped
     * string on that side of the join any more.
     */
    NeutrinoWebview.webView2Members = [
        { path: "lib/net462/Microsoft.Web.WebView2.Core.dll",
          sha256: "958efdb7f13a6d1f3079756c96956cc96cf713ae46fa085c8b1e7f44316a4f7e" },
        { path: "lib/net462/Microsoft.Web.WebView2.WinForms.dll",
          sha256: "a7b8be525030f19d9e88c6e684bca053dc7a3b080c31c3d9428f7438e7b6768f" },
        { path: "lib/net462/Microsoft.Web.WebView2.Wpf.dll",
          sha256: "217874fcb11722cf41a11c6d0483eab3f9d9c310d63486068f194614a7778a56" },
        { path: "runtimes/win-arm64/native/WebView2Loader.dll",
          sha256: "b0bfa03347a00169903c4ef0c27579dd9e85236a6dcd637a941d20b86eeec8fc" },
        { path: "runtimes/win-x64/native/WebView2Loader.dll",
          sha256: "a9a09232c25805323d4cfb3fc8f545a190a9c8a99c93262ea99d0b88df99ec90" },
        { path: "runtimes/win-x86/native/WebView2Loader.dll",
          sha256: "cbcd9a820b23aec9d68a95fb8cfd8c7d48e5bac1129faaf87aecabf4409a2ee2" }
    ];

    /*
     * The flat container serves the archive at its final address with no
     * redirect. The v2 API this used to call answers with the same bytes
     * but by way of a CDN hop, and a pin has no use for an extra place to
     * be wrong.
     */
    NeutrinoWebview.webView2PackageUrl = function () {
        var v = this.webView2PinnedVersion;
        return "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/" +
            v + "/microsoft.web.webview2." + v + ".nupkg";
    };

    NeutrinoWebview.sha256Hex = function (SystemRef, path) {
        var hasher = SystemRef.Security.Cryptography.SHA256.Create();
        var stream = SystemRef.IO.File.OpenRead(path);
        // Initialised, because the assignment below is inside a try and the
        // path where ComputeHash throws leaves this reachable and unset. It
        // rethrows there rather than returning, so nothing reads a null -- but
        // "might not be initialized" is a true thing for a compiler to say
        // about it, and a warning that is always there is one nobody reads.
        var digest = null;
        try {
            digest = hasher.ComputeHash(stream);
        } finally {
            stream.Close();
        }
        return String(SystemRef.BitConverter.ToString(digest)).replace(/-/g, "").toLowerCase();
    };

    /*
     * Returns null when every pinned member is present and hashes to what
     * it should, and the path of the first one that does not otherwise. An
     * unreadable file is a failure and not an exception: the caller's answer
     * to both is the same, which is to throw the directory away and fetch
     * the package again.
     */
    NeutrinoWebview.firstBadWebView2Member = function (SystemRef, packageRoot) {
        for (var i = 0; i < this.webView2Members.length; i++) {
            var member = this.webView2Members[i];
            var full = SystemRef.IO.Path.Combine(packageRoot, member.path.replace(/\//g, "\\"));
            try {
                if (!SystemRef.IO.File.Exists(full)) {
                    return member.path;
                }
                if (this.sha256Hex(SystemRef, full) !== member.sha256) {
                    return member.path;
                }
            } catch (_) {
                return member.path;
            }
        }
        return null;
    };

    /*
     * In process, and that is the whole of the fix. This used to build a
     * PowerShell command, base64 it, and hand `powershell.exe` to
     * ProcessStartInfo with UseShellExecute false -- so .NET gave
     * CreateProcess a null lpApplicationName and the name went through the
     * CreateProcess search order, whose first two entries are the directory
     * the calling exe was loaded from and the current directory. Both of
     * those are the app folder: the exe lives there, and the batch region
     * STARTs it with /D "%APP_FOLDER%". Measured on a runner, both entries
     * independently: a program named powershell.exe planted beside the exe
     * ran, one planted in the current directory ran, and the real one runs
     * only when neither is there.
     *
     * That folder is one everything running as this user can write -- the
     * sentence test/appcache.ps1 already carries -- and under netinstall
     * that includes the confined app. So this is PR 3's finding in Windows
     * spelling: write xor execute stops an app running what it wrote, and
     * does not stop it asking someone else to run it.
     *
     * An absolute path under Environment.SystemDirectory, with a working
     * directory beside it, was measured to refuse both plants and is not
     * what shipped. The command being sent was two calls out of
     * System.IO.Compression, so the answer available here is to name no
     * program at all, which is also the one that cannot be got wrong again
     * by a later edit. The assemblies come from the batch region's jsc
     * line; every call below is late-bound, so dropping them builds and
     * fails at run time -- see the comment there.
     *
     * The member names are literals from webView2Members, which is what
     * keeps Path.Combine from being handed an archive-supplied string. That
     * was PR 8's decision and it is unchanged: this iterates the pinned
     * list and asks the archive for each name.
     */
    NeutrinoWebview.extractWebView2Members = function (SystemRef, archivePath, destinationPath) {
        var archive = null;
        try {
            archive = SystemRef.IO.Compression.ZipFile.OpenRead(String(archivePath));
            for (var i = 0; i < this.webView2Members.length; i++) {
                var name = this.webView2Members[i].path;
                var entry = archive.GetEntry(name);
                if (entry == null) {
                    throw new Error("WebView2 package is missing " + name + ".");
                }
                var out = SystemRef.IO.Path.Combine(
                    String(destinationPath),
                    name.replace(/\//g, "\\")
                );
                var dir = SystemRef.IO.Path.GetDirectoryName(out);
                if (!SystemRef.IO.Directory.Exists(dir)) {
                    SystemRef.IO.Directory.CreateDirectory(dir);
                }
                SystemRef.IO.Compression.ZipFileExtensions.ExtractToFile(entry, out, true);
            }
        } finally {
            if (archive) {
                archive.Dispose();
            }
        }
    };

    /*
     * A recursive Directory.Delete and a directory junction: measured, and
     * not what it was expected to be. The framework does not walk through
     * the junction -- the target directory and its file were untouched --
     * it unlinks it, deletes everything else, and then throws
     * System.IO.IOException "The parameter is incorrect." having left the
     * directory itself behind, empty. So there is no delete of somewhere
     * else here, and this is not a boundary fix.
     *
     * What it is: that call sits inside the download's try, so a junction
     * planted anywhere under the package directory turns the next launch
     * into "Download/extract failed" for a reason nobody can act on, and
     * the launch after that succeeds because the directory is now empty.
     * A failure that repairs itself is a failure nothing ever reports,
     * which is why four PRs of CI never saw it.
     *
     * The walk below does what the framework was already doing about
     * reparse points and does not depend on the half that threw. 1024 is
     * FILE_ATTRIBUTE_REPARSE_POINT.
     *
     * test/winexec.ps1 asserts that no call in this file passes a recursive
     * flag, by reading the file -- so this paragraph deliberately does not
     * spell the call it is about. That is the third kind of hazard this
     * polyglot has where prose is structure, after PR 19's two sequences
     * and PR 24's sentinel; as there, the check is what catches it, on the
     * first run after somebody writes it.
     */
    NeutrinoWebview.deleteTree = function (SystemRef, dir) {
        var files = SystemRef.IO.Directory.GetFiles(dir);
        for (var i = 0; i < files.Length; i++) {
            SystemRef.IO.File.Delete(files[i]);
        }
        var subs = SystemRef.IO.Directory.GetDirectories(dir);
        for (var j = 0; j < subs.Length; j++) {
            var attrs = SystemRef.Convert.ToInt32(SystemRef.IO.File.GetAttributes(subs[j]));
            if ((attrs & 1024) !== 0) {
                SystemRef.IO.Directory.Delete(subs[j], false);
            } else {
                this.deleteTree(SystemRef, subs[j]);
            }
        }
        SystemRef.IO.Directory.Delete(dir, false);
    };

