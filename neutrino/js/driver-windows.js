    NeutrinoWebview.createWindowsDriver = function () {
        var SystemRef = eval("System");
        var webViewWinFormsAssembly, webViewType;
        // Initialised, not merely declared. preparePackage below reads
        // appFolder and is defined above the line in init that sets it, so
        // jsc.exe's definite-assignment pass has something to complain about
        // -- JS1187, "might not be initialized", on a runner and not here.
        // Both callers set it first; what this buys is a build with nothing in
        // its output, which is the only state in which a new warning is worth
        // anything.
        var appFolder = null, userDataDir = null;
        var self = this;
        var messageCallback = null;
        var lastDocTitle = "";
        var pendingPreload = null;
        var pendingPageScript = null;
        var pendingDocument = null;
        var settingsApplied = false;
        var webMessagesWired = false;
        // What is actually rendering, behind the nine calls the loop makes of
        // it. Two implementations -- see js/webview2-view.js -- and which one
        // this is was decided in init by whether the machine already has a
        // WebView2 runtime this build can reach.
        var view = null;
        // The Evergreen environment, when there is one. Null means the package
        // path, which is what every launch did before this and what every
        // launch still does when anything about the other one does not hold.
        var evergreen = null;
        // What init decided, and what attachWebView acts on. A plan is "this
        // machine has a runtime this build can reach"; `evergreen` is the
        // environment that came up from it, which does not exist until there is
        // a window to bring it up behind.
        var evergreenPlan = null;
        var viewClosed = false;

        /*
         * The package path's preparation, which used to be the tail of init and
         * is a function because two callers need it now: init, when there is no
         * runtime on the machine, and attachWebView, when there was one and it
         * would not start. Answers false having said why; the caller decides
         * whether that is fatal.
         */
        var preparePackage = function () {
            var webView2LibDir = self.ensureWebView2Package(SystemRef, appFolder);
            if (!webView2LibDir) {
                return false;
            }
            SystemRef.Environment.SetEnvironmentVariable("NEUTRINO_WEBVIEW2_LIB_DIR", webView2LibDir);
            self.prependLoaderPaths(SystemRef, webView2LibDir);
            SystemRef.Reflection.Assembly.LoadFrom(SystemRef.IO.Path.Combine(webView2LibDir, "Microsoft.Web.WebView2.Core.dll"));
            webViewWinFormsAssembly = SystemRef.Reflection.Assembly.LoadFrom(SystemRef.IO.Path.Combine(webView2LibDir, "Microsoft.Web.WebView2.WinForms.dll"));
            webViewType = webViewWinFormsAssembly.GetType("Microsoft.Web.WebView2.WinForms.WebView2");
            if (!webViewType) {
                throw new Error("Could not load Microsoft.Web.WebView2.WinForms.WebView2 type.");
            }
            self.trace("init: assemblies loaded from " + webView2LibDir);
            return true;
        };

        /*
         * The view, shut down before the window that carries it, and at most
         * once however many ways the run ends.
         *
         * Two ways in: the page called close(), and the user pressed the
         * frame's own button so the loop simply stopped. Both go through here,
         * because on the Evergreen path the order matters -- the controller
         * owns a child of this form's handle, and the runtime is documented to
         * be closed before its parent window is destroyed. The package view
         * answers this with nothing: its control is a child the form disposes.
         */
        var closeView = function () {
            if (viewClosed || !view) {
                return;
            }
            viewClosed = true;
            try {
                view.close();
            } catch (_) {}
        };

        return {
            /*
             * A placeholder. Which transport the page is given cannot be
             * decided here, because it depends on whether the event
             * subscription takes, and CoreWebView2 does not exist until the
             * event loop is running. So the preload is rebuilt there and
             * this only has to be non-empty for boot to ask for one at all.
             *
             * Where it does end up being the title, the record is encoded:
             * a record separator is a control character and a window title
             * is not a faithful carrier for those.
             */
            webMessageTransport: "function(m){document.title='__NEUTRINO__'+encodeURIComponent(m);}",
            transportName: "title",
            init: function () {
                SystemRef.Windows.Forms.Application.EnableVisualStyles();
                SystemRef.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);

                // Not StartupPath. The exe is kept beside the script now
                // rather than inside the app folder, so where this program
                // sits and where it may write are two different places --
                // windowsLayout is the one rule that answers both.
                appFolder = self.windowsLayout(SystemRef).appFolder;
                if (!SystemRef.IO.Directory.Exists(appFolder)) {
                    SystemRef.IO.Directory.CreateDirectory(appFolder);
                }
                userDataDir = SystemRef.IO.Path.Combine(appFolder, "data");

                // Before the package, because the package phase is one of
                // the two halves a stalled launch has to be split into. A
                // release build's installWindowsTrace is an empty function --
                // see js/windows-trace.js.
                self.installWindowsTrace(SystemRef, appFolder);
                self.trace("init: app folder " + appFolder);

                /*
                 * Before either path chooses anything, because both of them end
                 * in a browser and both read this. The Evergreen path calls the
                 * runtime's entry point and the package path goes through the
                 * managed wrapper; the variable is the runtime's either way.
                 *
                 * Set unconditionally, including over one that arrived from
                 * outside -- see webView2BrowserArguments, where that is half
                 * the reason it exists.
                 */
                SystemRef.Environment.SetEnvironmentVariable(
                    "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS",
                    self.webView2BrowserArguments);
                self.trace("init: browser arguments set");

                /*
                 * The runtime already on the machine, before anything is
                 * fetched. It is there on almost every Windows install -- it
                 * ships with 11 and reached 10 through Windows Update -- and
                 * what the package adds on such a machine is a managed wrapper
                 * around it and nothing else.
                 *
                 * Every failure inside startEvergreen answers null, and null
                 * falls through to exactly the launch this driver has always
                 * done. That is what makes the entry point it uses affordable:
                 * a runtime that stops answering costs a first run its download
                 * again, not an app that will not start. See
                 * js/webview2-evergreen.js for what is being depended on.
                 */
                evergreenPlan = self.evergreenPlan(SystemRef);
                if (evergreenPlan) {
                    self.trace("init: evergreen runtime " +
                        (evergreenPlan.version ? evergreenPlan.version : "unversioned") +
                        " available, nothing to download");
                    return;
                }

                if (!preparePackage()) {
                    SystemRef.Environment.Exit(1);
                    return;
                }
            },
            readFile: function (path) {
                return SystemRef.IO.File.ReadAllText(path);
            },
            /*
             * Derived, not received. This used to take the document's path
             * from NEUTRINO_SCRIPT_PATH -- an environment variable that
             * ends at "which document does this process execute", which is
             * the same shape findWebView2LibDir carries for its own
             * variable and gets the same answer here. netinstall's
             * allowlist keeps the whole NEUTRINO_ prefix, so it arrived
             * intact there too; a release build no longer reads it, and the
             * tests that need to point at another document build with the
             * testing build. The batch region has stopped setting it, so on
             * both launch paths the name an attacker would set is one
             * nothing reads.
             *
             * The derivation itself is windowsLayout, which the app folder
             * is resolved from too -- see the comment there. It also makes
             * the exe runnable on its own, which it was not.
             */
            getScriptPath: function () {
                // Named for what it is. `override` is a member modifier in
                // JScript.NET, and this file has already been caught once
                // by a name that means something to jsc and nothing to the
                // other three -- see the quoted "close" below.
                //
                // A release build's scriptPathOverride returns null and reads
                // no environment variable at all -- see js/windows-scriptpath.js.
                var fromEnv = self.scriptPathOverride(SystemRef);
                if (fromEnv) {
                    return fromEnv;
                }
                return self.windowsLayout(SystemRef).script;
            },
            readTheme: function () {
                return self.readWindowsTheme(SystemRef);
            },
            repaint: function (win, wv, background) {
                var color = self.makeWindowsColor(SystemRef, background);
                if (!color) {
                    return;
                }
                try {
                    win.BackColor = color;
                } catch (e) {
                    self.note("could not repaint the window: " + e);
                }
                // Through the view, because what a view paints is the one
                // thing the two engines do differently: a control has a
                // property and a controller has a second interface. Before
                // there is a view -- boot repaints once on the way up -- the
                // package path's control is all there is to paint.
                if (view) {
                    view.paint(color);
                } else if (wv) {
                    self.paintWindowsView(wv, color);
                }
            },
            evaluate: function (wv, js) {
                // The gate every lane holds, spelled the way this one keeps
                // it: `armed` is set from inside the engine at the commit of
                // the document this file navigated to.
                if (!view || !NeutrinoNavSink.armed) {
                    return;
                }
                view.evaluate(js);
            },
            createWindow: function (config) {
                /*
                 * The last dark stretch before the first paint. Measured on a
                 * runner, unloaded: the theme read lands at 77ms and the window
                 * is on screen at 227ms, and the hundred and fifty between them
                 * is two unrelated things -- boot reading the artifact back off
                 * disk and cutting the document out of it, and a Form being
                 * built and shown. Which of the two it mostly is decides
                 * whether that work is worth moving behind the window, and
                 * nothing here could say.
                 */
                self.trace("window  building the frame");
                var win = new SystemRef.Windows.Forms.Form();
                win.Text = config.title;
                /*
                 * Before ClientSize and not after it. A Form recomputes one
                 * of the two sizes when its border style changes, and which
                 * one it keeps is not a promise worth relying on -- setting
                 * the frame first leaves ClientSize as the last word, which
                 * is the quantity this lane is asked for and the quantity
                 * every other lane sets.
                 */
                if (self.undecorated()) {
                    win.FormBorderStyle = SystemRef.Windows.Forms.FormBorderStyle.None;
                }
                win.ClientSize = new SystemRef.Drawing.Size(config.width, config.height);
                win.StartPosition = SystemRef.Windows.Forms.FormStartPosition.CenterScreen;
                var winColor = self.makeWindowsColor(SystemRef, self.resolveBackground(self.theme));
                if (winColor) {
                    try { win.BackColor = winColor; } catch (e) { self.note("could not paint the window: " + e); }
                }
                return win;
            },
            createWebView: function () {
                /*
                 * On the Evergreen path there is no control to make. A
                 * controller is created from the environment against the
                 * window's own handle, and boot hands the window over one call
                 * later -- so the placeholder is what travels between them.
                 *
                 * On the plan rather than on the environment, because the
                 * environment does not exist yet: it is started in
                 * attachWebView, behind the window. What is decided by now is
                 * which kind of view this launch is going to build, which is
                 * all this call has ever needed to know.
                 */
                if (evergreenPlan) {
                    return { evergreen: true };
                }
                var wv = SystemRef.Activator.CreateInstance(webViewType);
                self.paintWindowsView(wv,
                    self.makeWindowsColor(SystemRef, self.resolveBackground(self.theme)));
                if (userDataDir) {
                    try {
                        var cpType = webViewWinFormsAssembly.GetType("Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties");
                        if (cpType) {
                            var cp = SystemRef.Activator.CreateInstance(cpType);
                            try {
                                cp.UserDataFolder = userDataDir;
                                SystemRef.IO.Directory.CreateDirectory(cp.UserDataFolder);
                                wv.CreationProperties = cp;
                            } catch (_) {}
                        }
                    } catch (_) {}
                }
                wv.Dock = SystemRef.Windows.Forms.DockStyle.Fill;
                return wv;
            },
            attachWebView: function (win, wv) {
                /*
                 * On screen here, and not in runEventLoop where the Show used
                 * to be. This is the other end of the complaint the splash
                 * answers from netinstall's side: the window was appearing
                 * after the WebView2 controller had been created and waited
                 * for, so everything that pump costs was time with nothing on
                 * screen at all.
                 *
                 * There is nothing to wait for. The Form is built, it is
                 * painted with the desktop's own colour -- or the one the build
                 * named -- and that is exactly the surface `background` exists
                 * to put up before the document arrives. Showing it earlier
                 * does not make an empty window last longer; it makes the same
                 * empty window start sooner, and the run below is unchanged.
                 *
                 * DoEvents once behind it, so the first paint happens now
                 * rather than on whichever later pump gets round to it. The
                 * controller's own pumpUntil calls DoEvents too, so the window
                 * stays responsive across the wait that follows this line.
                 *
                 * And the browser is started before it rather than after,
                 * which is the one thing here that is not simply "show it
                 * sooner".
                 *
                 * Measured on a runner, unloaded: the frame is built at 99ms,
                 * the window is on screen at 230ms, and the controller comes up
                 * at 649ms. The middle hundred and thirty is a Form being
                 * constructed and painted; the four hundred after it is a
                 * browser starting. The browser needs a window *handle*, and a
                 * Form realises one on demand -- CreateCoreWebView2Controller
                 * reads win.Handle, which creates it there and then without
                 * putting anything on screen. So the request goes in first and
                 * returns at once, and the frame is painted while the browser
                 * is already coming up behind it.
                 *
                 * What it costs is the environment's own thirty-odd
                 * milliseconds, which now land before the first paint instead
                 * of after it. That is the trade and it is the right way round:
                 * the far end of the launch loses more than the near end gains,
                 * and the near end moves by an amount nobody can see.
                 *
                 * The fallback stays below the paint. A runtime that will not
                 * start is a package download, and that is not a thing to do to
                 * somebody with an empty desktop in front of them.
                 */
                if (evergreenPlan) {
                    evergreen = self.startEvergreen(SystemRef, userDataDir, evergreenPlan);
                    if (evergreen) {
                        self.evergreenAskForController(SystemRef, evergreen, win);
                    }
                }
                win.Show();
                SystemRef.Windows.Forms.Application.DoEvents();
                /*
                 * The first paint, which is the one number a person launching
                 * this can see, and the timeline had no mark for it. Everything
                 * before this line is what they wait at an empty desktop for,
                 * and everything after it is what they wait at an empty window
                 * for -- two different complaints that the trace could not tell
                 * apart.
                 */
                self.trace("attach  window on screen");
                if (evergreenPlan) {
                    if (!evergreen) {
                        /*
                         * The runtime is on the machine and would not start,
                         * which is the case init used to catch by trying it
                         * first. Falling back still works and now does it with
                         * a window up rather than with nothing on screen -- but
                         * boot is holding the placeholder createWebView
                         * answered and never looks at it again -- every call
                         * after this one goes through `view` -- so the control
                         * made here is the one on the form and boot is none the
                         * wiser. What does have to be replayed is loadHTML,
                         * which already ran against the placeholder;
                         * pendingDocument survived it, so the document is not
                         * re-read or re-built, only pointed at.
                         */
                        evergreenPlan = null;
                        self.trace("attach: the runtime would not start; " +
                            "falling back to the package");
                        if (!preparePackage()) {
                            throw new Error("neutrino: the installed WebView2 " +
                                "runtime would not start and the package could " +
                                "not be fetched");
                        }
                        // Same order the ordinary package path is in, where
                        // loadHTML has already set Source by the time this
                        // function wraps the control: about:blank, then the
                        // view, then the form.
                        var made = this.createWebView();
                        made.Source = new SystemRef.Uri("about:blank");
                        view = self.managedView(SystemRef, made);
                        win.Controls.Add(made);
                        return;
                    }
                }
                if (evergreen) {
                    // The handle, which is the first moment there is one: a
                    // Form makes it on demand and boot has not shown the window
                    // yet. A controller that cannot be had here is not a
                    // failure worth falling back from -- the environment
                    // already came up, so the runtime is there and something
                    // else is wrong -- but it is worth saying out loud.
                    view = self.evergreenView(SystemRef, evergreen, win);
                    if (!view) {
                        throw new Error("neutrino: the installed WebView2 runtime " +
                            "started but would not give this window a view");
                    }
                    // Painted before it is sized and long before it is
                    // navigated to. There is exactly one chance to get this
                    // right: a view repainted after it is on screen is the
                    // flash, in a different colour.
                    view.paint(self.makeWindowsColor(SystemRef,
                        self.resolveBackground(self.theme)));
                    view.syncBounds();
                    return;
                }
                view = self.managedView(SystemRef, wv);
                win.Controls.Add(wv);
            },
            loadHTML: function (wv, html) {
                // Kept, not dropped. This driver used to throw the document
                // boot had extracted and applied the content policy to on
                // the floor, and read the file off NEUTRINO_SCRIPT_PATH a
                // second time inside the event loop to make another one.
                // Measured: the exe appears about 350 ms in and the second
                // read lands between half a second and a second after that,
                // so a file replaced inside the gap was the one that
                // rendered -- content policy and all -- while the page
                // script running in it came from the first read. The folder
                // it sits in is one appcache.ps1 measured this account can
                // write.
                //
                // about:blank still has to come first: CoreWebView2 does
                // not exist yet and nothing can be handed a string until it
                // does. What changes is where the string comes from then.
                pendingDocument = html;
                wv.Source = new SystemRef.Uri("about:blank");
            },
            setTitle: function (win, title) {
                win.Text = title;
                // The app's own clock on the one thing the verifier watches
                // for. A title the suite never saw and a title never set
                // are the same reading from outside and different ones
                // here.
                self.trace("title -> " + title);
            },
            resize: function (win, w, h) {
                win.ClientSize = new SystemRef.Drawing.Size(parseInt(w), parseInt(h));
            },
            move: function (win, x, y) {
                win.Location = new SystemRef.Drawing.Point(parseInt(x), parseInt(y));
            },
            // ClientSize and Location, matching the two above: this lane
            // sizes the content and positions the frame, and a relative
            // verb has to be relative to the same thing its absolute
            // sibling sets.
            getBounds: function (win) {
                return {
                    width: SystemRef.Convert.ToInt32(win.ClientSize.Width),
                    height: SystemRef.Convert.ToInt32(win.ClientSize.Height),
                    x: SystemRef.Convert.ToInt32(win.Location.X),
                    y: SystemRef.Convert.ToInt32(win.Location.Y)
                };
            },
            openExternal: function (url) {
                // Process.Start on a bare string is ShellExecute, which will
                // open a document, a .desktop-equivalent, or a registered
                // protocol handler just as happily as a web page. The
                // allowlist is what keeps it to web pages.
                if (!self.mayOpenExternal(url)) {
                    return;
                }
                var info = new SystemRef.Diagnostics.ProcessStartInfo(String(url));
                info.UseShellExecute = true;
                SystemRef.Diagnostics.Process.Start(info);
            },
            showWindow: function () {},
            // Quoted for the same reason boot() reaches for it that way:
            // jsc.exe is stricter than the other three engines about names
            // that look like they might mean something.
            "close": function (win) {
                closeView();
                win.Close();
            },
            onWebMessage: function (cb) {
                messageCallback = cb;
            },
            injectPreload: function (wv, js) {
                pendingPreload = js;
            },
            injectPageScript: function (js) {
                pendingPageScript = js;
            },
            runEventLoop: function (win, wv) {
                win.Show();
                self.trace("loop: window shown");
                var driver = this;
                var coreReady = false;
                var preloadInjected = false;
                var trustedRemembered = false;
                // Heartbeat and first-exception state. The loop body below
                // is one big try/catch that discards what it catches, so a
                // build whose every iteration threw would spin in silence
                // and look exactly like one waiting patiently.
                var spins = 0;
                var beats = 0;
                var loopExNoted = false;
                /*
                 * Pump, work, *then* sleep. It used to pump, sleep and then
                 * work, which put a sixteen millisecond wait in front of every
                 * state this machine advances through -- and on the Evergreen
                 * path the first of those states is already true when the loop
                 * starts, so the wait bought nothing at all. Three transitions
                 * stand between a ready view and the navigation that ends in
                 * the app's first paint, and each of them was one sleep late.
                 *
                 * The pump stays at the top: on the package path view.ready()
                 * is a control finishing its own startup, and that finishes on
                 * messages this line delivers.
                 */
                while (win.Visible) {
                    SystemRef.Windows.Forms.Application.DoEvents();
                    try {
                        // On the package path this is the control handing
                        // over its CoreWebView2, which does not exist until the
                        // runtime has finished starting -- well after the
                        // window is on screen. On the Evergreen path it was
                        // ready before the window was shown, and the answer is
                        // true on the first turn.
                        if (!coreReady) {
                            coreReady = view.ready();
                        }
                        if (coreReady && !settingsApplied) {
                            settingsApplied = true;
                            self.trace("loop: " + view.name + " view ready after " +
                                spins + " turns");
                            view.harden();

                            // Before the preload is built, because what the
                            // page is told to send on depends on whether
                            // this took.
                            webMessagesWired = view.wireMessages();
                            // Before anything is injected and before the
                            // app's own document is navigated to, so the
                            // gate is armed by that navigation and not
                            // after it.
                            view.wireNavigation();
                            pendingPreload = self.buildPreloadScript(
                                webMessagesWired
                                    ? "function(m){window.chrome.webview.postMessage(m);}"
                                    : "function(m){document.title='__NEUTRINO__'+encodeURIComponent(m);}",
                                webMessagesWired ? "webmessage" : "title",
                                // This lane builds its preload here rather
                                // than in boot, so the palette has to be
                                // put in here too. Left out, every Windows
                                // app would read neutrino.theme as null
                                // while the window it is sitting in was
                                // painted from a palette that was read
                                // perfectly well.
                                self.themeLiteral(self.theme)
                            );
                        }
                        if (coreReady && pendingPreload && !preloadInjected) {
                            preloadInjected = true;
                            // The API first, then the page's own code, both
                            // through the engine so the document itself can
                            // forbid script.
                            //
                            // The API at document creation, and the app held
                            // back until there is a document -- which is what
                            // every other lane's engine does for it and what
                            // this one has to be asked for. deferredPageScript
                            // says why, and what it cost before.
                            view.addScripts(pendingPageScript
                                ? [pendingPreload,
                                   self.deferredPageScript(pendingPageScript)]
                                : [pendingPreload]);
                            if (pendingDocument) {
                                /*
                                 * Set before the call and not after it. The
                                 * navigation is queued here and its events
                                 * fire on the DoEvents below, so a flag set
                                 * after Invoke returns is still set in time
                                 * -- but only by luck of this method not
                                 * pumping, and the guard reads the flag
                                 * from inside the engine.
                                 */
                                NeutrinoNavSink.navIssued = true;
                                self.trace("loop: navigating to the app document");
                                view.navigateToString(pendingDocument);
                            } else {
                                // The other half of the same finding, and
                                // the quieter one. When the second read
                                // found no file the condition above was
                                // simply false: no navigation, the view
                                // left on the about:blank it was created
                                // with, and the page script never reached
                                // an API to report through. Measured twice
                                // as a window with no title, no error and
                                // no log line at all. There is no read to
                                // fail any more, and if this is ever
                                // reached it says so.
                                self.note("the view was given no document; the window will stay blank");
                            }
                        }
                        if (coreReady) {
                            self.drainNavRefusals(driver);
                            // A controller is a rectangle somebody has to set,
                            // and on this lane that somebody is this loop. The
                            // package view is docked and answers this with
                            // nothing.
                            view.syncBounds();
                        }
                        /*
                         * The theme watcher, and on this lane it is a
                         * re-read rather than a subscription.
                         *
                         * This loop already spins at 16 ms doing reflection
                         * on every turn, so reading two SystemColors and
                         * one registry value once a second is nothing next
                         * to what it is already paying -- and it needs no
                         * delegate bound to an event whose handler type
                         * would be one more thing to discover at run time.
                         * applyTheme's diff is what makes a re-read safe to
                         * do on a clock: a palette that has not changed is
                         * not an update, so the page hears nothing until
                         * something actually happens.
                         *
                         * SystemEvents.UserPreferenceChanged is the real
                         * mechanism if this ever measures badly. It was not
                         * taken first because it is strictly more moving
                         * parts for an answer this loop can already reach.
                         */
                        if (spins % 60 === 0) {
                            self.applyTheme(driver, win, wv, driver.readTheme());
                        }
                        if (coreReady && messageCallback && webMessagesWired) {
                            var arrived = view.takeMessages();
                            for (var mi = 0; mi < arrived.length; mi++) {
                                messageCallback(arrived[mi]);
                            }
                        }
                        /*
                         * The document's title, read on the same clock and
                         * now read whatever the transport is.
                         *
                         * One property with two meanings, and the marker is
                         * what separates them. Where wireWebView2Messages
                         * returned false the title *is* the channel, so a
                         * marked value is a record and is handed to the
                         * callback. Everything else is a name the document
                         * chose, and this lane's half of the title hook is
                         * to put it on the Form -- which is why this read
                         * moved out of the branch it used to live in: with
                         * webmessages wired, which is every run on this
                         * lane that CI has ever recorded, it never ran.
                         *
                         * Who set it, asked the same way readWebView2Message
                         * asks. This used to ask nothing at all, which made
                         * this the one driver that never checked a sender --
                         * and wherever the title is the whole channel, a
                         * page navigated to could drive the native window by
                         * writing its own.
                         *
                         * Source is the reading that makes it checkable and
                         * it had to be measured: the view's Source stays
                         * about:blank across the driver's NavigateToString,
                         * and names the remote document once a navigation
                         * has arrived -- polled on this same clock, a
                         * foreign title and a foreign Source were seen in
                         * the same pair.
                         *
                         * A view that cannot say what it is showing is
                         * refused rather than trusted, which is the rule
                         * isTrustedView already settled.
                         */
                        /*
                         * And not after the view has gone. A page that called
                         * close() did so from the message drain a few lines
                         * up, so this turn is still running with a controller
                         * that has been shut down -- every read below would
                         * throw into the catch and write one puzzled trace
                         * line about a window that closed exactly as asked.
                         */
                        if (coreReady && !viewClosed) {
                            /*
                             * The fifth lane arming the way the other four
                             * do, and remembering the reading it is going to
                             * compare.
                             *
                             * NeutrinoNavSink.armed is this lane's commit --
                             * the document this file navigated to has
                             * arrived. What gets remembered is `Source`, and
                             * that is the whole of the fix: the sink's
                             * `ownDocument` is the `data:` url the
                             * navigation event reported, while `Source`
                             * stays `about:blank` for the life of the view.
                             * Remembering the first and checking the second
                             * is a guard that can never pass, and it shipped
                             * once: every title on this lane was refused,
                             * and since the title is the only report channel
                             * here, every suite on the platform went dark at
                             * the same moment.
                             *
                             * Remembered here rather than inside the sink,
                             * which stays a .NET static with no reach into
                             * this object -- the arrangement that makes it
                             * unreachable from any document.
                             */
                            if (!trustedRemembered && NeutrinoNavSink.armed) {
                                var committed = view.source();
                                if (committed !== null && committed !== "") {
                                    trustedRemembered = true;
                                    self.rememberTrustedView(committed);
                                }
                            }
                            // Nothing is read until there is a document to
                            // judge it against. lastDocTitle is what turns
                            // this poll into an edge, so latching a title
                            // that would be refused for arriving too early
                            // would swallow it for the rest of the run.
                            //
                            // And that is true one gate further down as well.
                            // `trustedRemembered` is not the only thing that
                            // can refuse a title here: acceptDocumentTitle
                            // refuses any title while the view is not showing
                            // this launcher's own document, and the latch used
                            // to be taken before it was asked -- so a title
                            // refused once was recorded as seen and never
                            // offered again. Measured on the macOS poll, which
                            // had the identical shape and lost a probe state in
                            // two rounds out of four; this lane has not been
                            // seen to lose one, and is exposed the same way.
                            //
                            // A record is different and still latches where it
                            // is handled. It is consumed rather than judged --
                            // re-reading one would deliver the same message to
                            // the page's channel twice, which is worse than
                            // dropping it. Only the *name* branch waits for an
                            // acceptance before it latches.
                            if (trustedRemembered) {
                                var docTitle = view.documentTitle();
                                if (docTitle !== lastDocTitle) {
                                    var showing = view.source();
                                    if (docTitle.indexOf(self.recordPrefix) === 0) {
                                        lastDocTitle = docTitle;
                                        var mine = (showing !== null) && self.isOwnDocument(showing);
                                        if (!messageCallback || webMessagesWired) {
                                            // A record on a lane whose
                                            // channel is elsewhere. Nothing
                                            // is listening for it here and
                                            // it is not a name either, so it
                                            // goes no further in either
                                            // direction.
                                            self.trace("a record arrived in the title and the channel is " +
                                                (webMessagesWired ? "webmessage" : "unwired"));
                                        } else if (mine) {
                                            try {
                                                messageCallback(decodeURIComponent(
                                                    docTitle.substring(self.recordPrefix.length)));
                                            } catch (_) {}
                                        } else {
                                            self.note("refused a record in the title of " +
                                                (showing === null ? "a view that did not say" : showing));
                                        }
                                    } else {
                                        var name = self.acceptDocumentTitle(
                                            showing === null ? "" : showing, docTitle);
                                        if (name !== null) {
                                            lastDocTitle = docTitle;
                                            driver.setTitle(win, name);
                                        }
                                    }
                                }
                            }
                        }
                    } catch (loopEx) {
                        /*
                         * Still swallowed -- this loop has always been
                         * allowed to outlive a bad turn -- but no longer in
                         * silence. Once, and only under a testing build.
                         *
                         * String() and not a typed catch: `catch (ex :
                         * Exception)` is the spelling that reaches the CLR
                         * exception (PR 25) and it is JScript.NET syntax,
                         * which the three engines that also parse this file
                         * would refuse. So this names that something threw
                         * and roughly what; the type may arrive wrapped.
                         */
                        if (!loopExNoted) {
                            loopExNoted = true;
                            // Guarded, like everything else on this path:
                            // an instrument that can end the loop it is
                            // watching is worse than no instrument.
                            try {
                                self.trace("loop: raised " + String(loopEx));
                            } catch (_) {}
                        }
                    }
                    /*
                     * A heartbeat while the engine has not arrived. Sixteen
                     * milliseconds a turn, so this is about every five
                     * seconds, and it stops after forty -- long enough to
                     * cover a 240s wait, bounded so a wedged launch cannot
                     * write an unbounded file.
                     */
                    SystemRef.Threading.Thread.Sleep(16);
                    spins++;
                    if (!coreReady && beats < 40 && spins % 300 === 0) {
                        beats++;
                        try {
                            self.trace("loop: still no view after " +
                                spins + " turns");
                        } catch (_) {}
                    }
                }
                // However the window went -- the page's close() or the frame's
                // own button -- the view goes with it. Idempotent, so the run
                // that came through driver.close has already done this.
                closeView();
            },
            handleError: function (ex) {
                var message = "";
                try {
                    if (ex && ex.message) { message = String(ex.message); }
                } catch (_) {}
                /*
                 * The heading used to be "Failed to initialize WebView2
                 * package/download." whatever had gone wrong. That was true
                 * of the one failure that could reach here and it is not
                 * true of the ones that can now: a file this launcher
                 * cannot split, and a document whose policy refuses before
                 * any download starts. An error
                 * this file raises says so in its own words and keeps them.
                 */
                var detail;
                if (message.indexOf("neutrino:") === 0) {
                    detail = message;
                } else {
                    detail = "Failed to initialize WebView2 package/download.";
                    if (message) { detail = detail + "\n\n" + message; }
                }
                self.showWindowsError(SystemRef, "neutrino", detail);
                SystemRef.Environment.Exit(1);
            }
        };
    };

    NeutrinoWebview.runWindows = function () {
        var driver = this.createWindowsDriver();
        try {
            this.boot(driver, this.config);
        } catch (ex) {
            driver.handleError(ex);
        }
    };
