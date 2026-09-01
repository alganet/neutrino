    NeutrinoWebview.createWindowsDriver = function () {
        var SystemRef = eval("System");
        var webViewWinFormsAssembly, webViewType;
        var appFolder, userDataDir;
        var self = this;
        var messageCallback = null;
        var lastDocTitle = "";
        var pendingPreload = null;
        var pendingPageScript = null;
        var pendingDocument = null;
        var settingsApplied = false;
        var webMessagesWired = false;
        // Kept because evaluate needs it and the loop is the only place it
        // can be got: CoreWebView2 does not exist until the runtime has
        // finished starting, which is well after the window is on screen.
        var coreWebView2 = null;

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
                // the two halves a stalled launch has to be split into.
                if (self.hasTier("testing")) {
                    self.installWindowsTrace(SystemRef, appFolder);
                }
                self.trace("init: app folder " + appFolder);

                var webView2LibDir = self.ensureWebView2Package(SystemRef, appFolder);
                if (!webView2LibDir) {
                    SystemRef.Environment.Exit(1);
                    return;
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
             * testing tier. The batch region has stopped setting it, so on
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
                if (self.hasTier("testing")) {
                    var fromEnv = SystemRef.Environment.GetEnvironmentVariable("NEUTRINO_SCRIPT_PATH");
                    // Tested against null and "" rather than for truth.
                    // Every value here is a .NET String arriving through a
                    // late-bound call, and whether an empty one is falsy is
                    // a question the four engines do not have to answer the
                    // same way. Nothing below asks.
                    if (fromEnv != null && String(fromEnv) !== "") {
                        if (!SystemRef.IO.File.Exists(fromEnv)) {
                            throw new Error("neutrino: NEUTRINO_SCRIPT_PATH names no file: " + fromEnv);
                        }
                        return fromEnv;
                    }
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
                if (wv) {
                    self.paintWindowsView(wv, color);
                }
            },
            evaluate: function (wv, js) {
                // The gate every lane holds, spelled the way this one keeps
                // it: `armed` is set from inside the engine at the commit of
                // the document this file navigated to.
                if (!coreWebView2 || !NeutrinoNavSink.armed) {
                    return;
                }
                var run = coreWebView2.GetType().GetMethod("ExecuteScriptAsync");
                if (!run) {
                    return;
                }
                run.Invoke(coreWebView2, [js]);
            },
            createWindow: function (config) {
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
                var coreWv2 = null;
                var titleProp = null;
                var sourceProp = null;
                var preloadInjected = false;
                var trustedRemembered = false;
                // Heartbeat and first-exception state. The loop body below
                // is one big try/catch that discards what it catches, so a
                // build whose every iteration threw would spin in silence
                // and look exactly like one waiting patiently.
                var spins = 0;
                var beats = 0;
                var loopExNoted = false;
                while (win.Visible) {
                    SystemRef.Windows.Forms.Application.DoEvents();
                    SystemRef.Threading.Thread.Sleep(16);
                    try {
                        if (!coreWv2 && wv) {
                            var coreWv2Prop = wv.GetType().GetProperty("CoreWebView2");
                            if (coreWv2Prop) {
                                coreWv2 = coreWv2Prop.GetValue(wv, null);
                                // Kept where evaluate can reach it. This
                                // is the only place it can be got.
                                coreWebView2 = coreWv2;
                            }
                        }
                        if (coreWv2 && !settingsApplied) {
                            settingsApplied = true;
                            self.trace("loop: CoreWebView2 available after " + spins + " turns");
                            self.hardenWebView2(coreWv2);

                            // Before the preload is built, because what the
                            // page is told to send on depends on whether
                            // this took.
                            webMessagesWired = self.wireWebView2Messages(SystemRef, coreWv2);
                            // Before anything is injected and before the
                            // app's own document is navigated to, so the
                            // gate is armed by that navigation and not
                            // after it.
                            self.wireWebView2Navigation(SystemRef, coreWv2);
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
                        if (coreWv2 && pendingPreload && !preloadInjected) {
                            preloadInjected = true;
                            var addScript = coreWv2.GetType().GetMethod("AddScriptToExecuteOnDocumentCreatedAsync");
                            if (addScript) {
                                // The API first, then the page's own code,
                                // both through the engine so the document
                                // itself can forbid script.
                                var sources = pendingPageScript
                                    ? [pendingPreload, pendingPageScript]
                                    : [pendingPreload];
                                for (var si = 0; si < sources.length; si++) {
                                    var task = addScript.Invoke(coreWv2, [sources[si]]);
                                    if (task) {
                                        while (!task.IsCompleted) {
                                            SystemRef.Windows.Forms.Application.DoEvents();
                                            SystemRef.Threading.Thread.Sleep(10);
                                        }
                                    }
                                }
                            }
                            var navMethod = coreWv2.GetType().GetMethod("NavigateToString");
                            if (navMethod && pendingDocument) {
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
                                navMethod.Invoke(coreWv2, [pendingDocument]);
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
                        if (coreWv2) {
                            self.drainNavRefusals(driver);
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
                        if (coreWv2 && messageCallback && webMessagesWired) {
                            // Drained here rather than handled in the event
                            // itself: the queue is a .NET static, which no
                            // document can reach, so nothing is lost by
                            // reading it on the same clock as everything
                            // else in this loop.
                            while (NeutrinoWebMessageSink.queue.Count > 0) {
                                var queued = NeutrinoWebMessageSink.queue[0];
                                NeutrinoWebMessageSink.queue.RemoveAt(0);
                                var text = self.readWebView2Message(queued);
                                if (text !== null) {
                                    messageCallback(text);
                                }
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
                        if (coreWv2) {
                            if (!titleProp) {
                                titleProp = coreWv2.GetType().GetProperty("DocumentTitle");
                                sourceProp = coreWv2.GetType().GetProperty("Source");
                            }
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
                                var committed = self.readWebView2Source(coreWv2, sourceProp);
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
                            if (titleProp && trustedRemembered) {
                                var docTitle = String(titleProp.GetValue(coreWv2, null) || "");
                                if (docTitle !== lastDocTitle) {
                                    var showing = self.readWebView2Source(coreWv2, sourceProp);
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
                         * silence. Once, and only under the testing tier.
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
                    spins++;
                    if (!coreWv2 && beats < 40 && spins % 300 === 0) {
                        beats++;
                        try {
                            self.trace("loop: still no CoreWebView2 after " +
                                spins + " turns");
                        } catch (_) {}
                    }
                }
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
                 * cannot split, and a document the offline tier cannot make
                 * offline, both refuse before any download starts. An error
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
