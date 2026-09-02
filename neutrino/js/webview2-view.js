    /*
     * One shape, two engines behind it.
     *
     * The Windows event loop needs nine things from whatever is rendering: a
     * core to be ready, settings hardened, messages and navigation wired, the
     * preload injected, a document navigated to, messages drained, a title and
     * a source read, and script evaluated. It used to reach for all nine
     * through `coreWv2.GetType().GetMethod(...)`, which works when the types
     * come from a managed assembly and cannot work at all when they come from a
     * vtable.
     *
     * So the loop asks a view instead, and there are two. The package view is
     * the existing code moved behind the calls it already made. The Evergreen
     * view is the same nine operations against emitted COM interfaces.
     *
     * What is deliberately *not* forked: every rule about what is allowed. The
     * sender check on a message, the trusted-view gate, the title acceptance
     * and the navigation policy are one implementation each, and both views
     * feed them the same readings. A guard written twice is a guard that
     * disagrees with itself on a Tuesday.
     */

    /*
     * The package view: the WinForms control out of the NuGet assemblies.
     * Nothing here is new -- it is the driver's own calls, in the order the
     * loop made them, with the reflection they always used.
     */
    NeutrinoWebview.managedView = function (SystemRef, wv) {
        var self = this;
        var core = null;
        var titleProp = null;
        var sourceProp = null;

        return {
            name: "package",
            ready: function () {
                if (core) {
                    return true;
                }
                if (!wv) {
                    return false;
                }
                var prop = wv.GetType().GetProperty("CoreWebView2");
                if (!prop) {
                    return false;
                }
                core = prop.GetValue(wv, null);
                if (core) {
                    titleProp = core.GetType().GetProperty("DocumentTitle");
                    sourceProp = core.GetType().GetProperty("Source");
                }
                return !!core;
            },
            harden: function () {
                self.hardenWebView2(core);
            },
            wireMessages: function () {
                return self.wireWebView2Messages(SystemRef, core);
            },
            wireNavigation: function () {
                return self.wireWebView2Navigation(SystemRef, core);
            },
            /*
             * The API first, then the page's own code, both through the engine
             * so the document itself can forbid script. The task is waited on
             * by pumping, because the navigation that follows has to be second.
             */
            addScripts: function (sources) {
                var add = core.GetType().GetMethod("AddScriptToExecuteOnDocumentCreatedAsync");
                if (!add) {
                    return false;
                }
                for (var i = 0; i < sources.length; i++) {
                    var task = add.Invoke(core, [sources[i]]);
                    if (task) {
                        while (!task.IsCompleted) {
                            SystemRef.Windows.Forms.Application.DoEvents();
                            SystemRef.Threading.Thread.Sleep(10);
                        }
                    }
                }
                return true;
            },
            navigateToString: function (html) {
                var nav = core.GetType().GetMethod("NavigateToString");
                if (!nav) {
                    return false;
                }
                nav.Invoke(core, [html]);
                return true;
            },
            /*
             * Drained here rather than handled in the event itself: the queue
             * is a .NET static, which no document can reach, so nothing is lost
             * by reading it on the same clock as everything else in the loop.
             * readWebView2Message is where the sender is checked.
             */
            takeMessages: function () {
                var out = [];
                while (NeutrinoWebMessageSink.queue.Count > 0) {
                    var queued = NeutrinoWebMessageSink.queue[0];
                    NeutrinoWebMessageSink.queue.RemoveAt(0);
                    var text = self.readWebView2Message(queued);
                    if (text !== null) {
                        out.push(text);
                    }
                }
                return out;
            },
            documentTitle: function () {
                if (!titleProp) {
                    return "";
                }
                return String(titleProp.GetValue(core, null) || "");
            },
            source: function () {
                return self.readWebView2Source(core, sourceProp);
            },
            evaluate: function (js) {
                var run = core.GetType().GetMethod("ExecuteScriptAsync");
                if (!run) {
                    return false;
                }
                run.Invoke(core, [js]);
                return true;
            },
            paint: function (color) {
                return self.paintWindowsView(wv, color);
            },
            // The control is docked and the form resizes it. Nothing to do.
            syncBounds: function () {},
            close: function () {}
        };
    };

    /*
     * The Evergreen view: a controller created against the window's own handle,
     * and the interfaces behind it built by jsc/interop.jsc.
     *
     * Answers null rather than throwing when the controller will not come up,
     * because null is the caller falling back to the package -- which is the
     * whole reason an unsupported entry point is affordable here.
     */
    NeutrinoWebview.evergreenView = function (SystemRef, session, win) {
        var self = this;
        var types = session.types;
        var lastWidth = -1;
        var lastHeight = -1;

        var handler = NeutrinoEvergreen.MakeSink("NeutrinoCtlSink",
            this.webView2Handlers.controllerCompleted.iid,
            this.webView2Handlers.controllerCompleted.args,
            this.webView2Handlers.controllerCompleted.target);

        types.environment.GetMethod("CreateCoreWebView2Controller")
            .Invoke(session.environment, [win.Handle, handler]);
        this.pumpUntil(SystemRef, function () {
            return NeutrinoEvergreen.controllerDone;
        }, 60000);

        if (!NeutrinoEvergreen.controllerDone || NeutrinoEvergreen.controllerHr !== 0) {
            this.trace("evergreen: no controller (" + NeutrinoEvergreen.controllerHr + ")");
            return null;
        }
        var controller = NeutrinoEvergreen.Wrap(NeutrinoEvergreen.controllerPtr, types.controller);
        if (!controller) {
            return null;
        }
        var core = NeutrinoEvergreen.Wrap(
            types.controller.GetMethod("get_CoreWebView2").Invoke(controller, null),
            types.webview);
        if (!core) {
            this.trace("evergreen: the controller has no webview");
            return null;
        }

        /*
         * The background the view paints before it has a document, which is what
         * the package path gets from the control's DefaultBackgroundColor. It is
         * on a second interface with its own IID, so a runtime too old to offer
         * it refuses this QueryInterface -- and that costs the gap before the
         * first paint, not the app: the window underneath is already themed.
         */
        var controller2 = null;
        try {
            controller2 = NeutrinoEvergreen.Wrap(NeutrinoEvergreen.controllerPtr, types.controller2);
        } catch (e) {
            this.noteOnce("this WebView2 runtime cannot be told what to paint " +
                "before the document arrives: " + e);
        }

        var scriptAddedSink = NeutrinoEvergreen.MakeSink("NeutrinoAddSink",
            this.webView2Handlers.scriptAdded.iid,
            this.webView2Handlers.scriptAdded.args,
            this.webView2Handlers.scriptAdded.target);
        var scriptRanSink = NeutrinoEvergreen.MakeSink("NeutrinoRanSink",
            this.webView2Handlers.scriptRan.iid,
            this.webView2Handlers.scriptRan.args,
            this.webView2Handlers.scriptRan.target);

        // One string out, one call, one free. Every string in the table is an
        // IntPtr, so this is what a string parameter costs here.
        var withString = function (text, run) {
            var held = NeutrinoEvergreen.GiveString(String(text));
            try {
                return run(held);
            } finally {
                NeutrinoEvergreen.DropString(held);
            }
        };

        var subscribe = function (slot, which) {
            try {
                var sink = NeutrinoEvergreen.MakeSink("NeutrinoSink_" + which,
                    self.webView2Handlers[which].iid,
                    self.webView2Handlers[which].args,
                    self.webView2Handlers[which].target);
                types.webview.GetMethod(slot).Invoke(core, [sink]);
                return true;
            } catch (e) {
                self.note("could not subscribe to " + slot + ": " + e);
                return false;
            }
        };

        return {
            name: "evergreen",
            ready: function () {
                return true;
            },
            /*
             * Four of the nine doors the package view closes. The other five
             * are not on ICoreWebView2Settings at all -- they arrived in
             * Settings3 through 6, which are separate IIDs -- so this build
             * hardens less, and js/webview2-interfaces.js names which.
             */
            harden: function () {
                var settings = NeutrinoEvergreen.Wrap(
                    types.webview.GetMethod("get_Settings").Invoke(core, null),
                    types.settings);
                if (!settings) {
                    self.note("the view would not hand over its settings");
                    return;
                }
                var off = self.webView2Interfaces.settings.calls;
                var no = SystemRef.Convert.ToInt32(0);
                for (var name in off) {
                    if (!off.hasOwnProperty(name)) {
                        continue;
                    }
                    try {
                        types.settings.GetMethod(name).Invoke(settings, [no]);
                    } catch (_) {}
                }
            },
            wireMessages: function () {
                return subscribe("add_WebMessageReceived", "webMessageReceived");
            },
            wireNavigation: function () {
                var wired = 0;
                if (subscribe("add_NavigationStarting", "navigationStarting")) { wired++; }
                if (subscribe("add_ContentLoading", "contentLoading")) { wired++; }
                if (subscribe("add_NewWindowRequested", "newWindowRequested")) { wired++; }
                if (wired < 3) {
                    self.note("navigation guard wired " + wired + " of 3 events; " +
                        "a navigation may not be refused here");
                }
                return wired === 3;
            },
            addScripts: function (sources) {
                var method = types.webview.GetMethod("AddScriptToExecuteOnDocumentCreated");
                for (var i = 0; i < sources.length; i++) {
                    withString(sources[i], function (held) {
                        method.Invoke(core, [held, scriptAddedSink]);
                    });
                }
                return true;
            },
            navigateToString: function (html) {
                var method = types.webview.GetMethod("NavigateToString");
                withString(html, function (held) {
                    method.Invoke(core, [held]);
                });
                return true;
            },
            /*
             * The sender is judged here and not in the handler. The handler is
             * a .NET static and isOwnDocument is a JScript global, so the two
             * cannot meet -- and the alternative, a second rule written in
             * JScript.NET, is the guard-written-twice this file exists to
             * avoid. What the handler queues is what it saw.
             */
            takeMessages: function () {
                var out = [];
                while (NeutrinoEvergreen.messages.Count > 0) {
                    var from = String(NeutrinoEvergreen.messageSources[0]);
                    var text = String(NeutrinoEvergreen.messages[0]);
                    NeutrinoEvergreen.messageSources.RemoveAt(0);
                    NeutrinoEvergreen.messages.RemoveAt(0);
                    if (self.isOwnDocument(from)) {
                        out.push(text);
                    }
                }
                return out;
            },
            documentTitle: function () {
                try {
                    return String(NeutrinoEvergreen.TakeString(
                        types.webview.GetMethod("get_DocumentTitle").Invoke(core, null)));
                } catch (_) {
                    return "";
                }
            },
            /*
             * Measured to be `about:blank` for the life of the view, which is
             * what the package view reports too -- so the trusted-view gate
             * reads the same thing on both and there is one gate.
             */
            source: function () {
                try {
                    return String(NeutrinoEvergreen.TakeString(
                        types.webview.GetMethod("get_Source").Invoke(core, null)));
                } catch (_) {
                    return null;
                }
            },
            evaluate: function (js) {
                var method = types.webview.GetMethod("ExecuteScript");
                withString(js, function (held) {
                    method.Invoke(core, [held, scriptRanSink]);
                });
                return true;
            },
            /*
             * The one thing the package view gets for free. A WinForms control
             * is docked and the form resizes it; a controller is a rectangle
             * somebody has to set. Done on the loop's own clock rather than
             * through a Resize handler, because a handler needs a delegate type
             * and this driver has no way to name one.
             */
            /*
             * Set before anything is navigated to, and again whenever the
             * desktop palette moves -- the same two moments the package path
             * paints its control at.
             */
            paint: function (color) {
                if (!controller2 || !color) {
                    return false;
                }
                try {
                    types.controller2.GetMethod("put_DefaultBackgroundColor").Invoke(
                        controller2,
                        [NeutrinoEvergreen.MakeColour(color.R, color.G, color.B)]);
                    return true;
                } catch (e) {
                    self.noteOnce("could not paint the view: " + e);
                    return false;
                }
            },
            syncBounds: function () {
                var width = SystemRef.Convert.ToInt32(win.ClientSize.Width);
                var height = SystemRef.Convert.ToInt32(win.ClientSize.Height);
                if (width === lastWidth && height === lastHeight) {
                    return;
                }
                lastWidth = width;
                lastHeight = height;
                try {
                    types.controller.GetMethod("put_Bounds")
                        .Invoke(controller, [NeutrinoEvergreen.MakeRect(width, height)]);
                    types.controller.GetMethod("put_IsVisible")
                        .Invoke(controller, [SystemRef.Convert.ToInt32(1)]);
                } catch (e) {
                    self.noteOnce("could not size the view: " + e);
                }
            },
            close: function () {
                try {
                    types.controller.GetMethod("Close").Invoke(controller, null);
                } catch (_) {}
            }
        };
    };
