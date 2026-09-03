    /*
     * Reached by reflection because the type comes from an assembly loaded
     * at run time, and set one at a time so that a runtime too old to know
     * one property still gets the others. None of these are a sandbox --
     * WebView2 sandboxes its own renderers and that is the real boundary --
     * they close the doors this app has no use for.
     */
    NeutrinoWebview.hardenWebView2 = function (coreWv2) {
        var settings = null;
        try {
            settings = coreWv2.GetType().GetProperty("Settings").GetValue(coreWv2, null);
        } catch (_) {
            return;
        }
        if (!settings) {
            return;
        }

        var off = [
            "AreDevToolsEnabled",
            "AreDefaultContextMenusEnabled",
            "AreHostObjectsAllowed",
            "IsStatusBarEnabled",
            "IsSwipeNavigationEnabled",
            "AreBrowserAcceleratorKeysEnabled",
            "IsGeneralAutofillEnabled",
            "IsPasswordAutosaveEnabled",
            "IsPinchZoomEnabled"
        ];

        for (var i = 0; i < off.length; i++) {
            try {
                var prop = settings.GetType().GetProperty(off[i]);
                if (prop && prop.CanWrite) {
                    prop.SetValue(settings, false, null);
                }
            } catch (_) {}
        }
    };

    /*
     * Subscribe to CoreWebView2.WebMessageReceived. Everything here is
     * reflection because the types arrive with an assembly loaded at run
     * time, and the delegate is built by CreateDelegate against the event's
     * own handler type for the same reason.
     *
     * Returns true only if the subscription actually took. The caller keeps
     * reading the document title when it did not, because a Windows build
     * with no channel at all is worse than one with a channel a page can
     * write to -- but it is a real downgrade, so it is named in the report
     * rather than left to be inferred.
     */
    NeutrinoWebview.wireWebView2Messages = function (SystemRef, coreWv2) {
        try {
            var evt = coreWv2.GetType().GetEvent("WebMessageReceived");
            if (!evt) {
                return false;
            }
            var sink = new NeutrinoWebMessageSink();
            var handler = SystemRef.Delegate.CreateDelegate(
                evt.EventHandlerType, sink, sink.GetType().GetMethod("Handle")
            );
            evt.AddEventHandler(coreWv2, handler);
            return true;
        } catch (_) {
            return false;
        }
    };

    /*
     * The navigation policy, and the platform PRs 5 and 6 left out. gjs, Qt
     * and macOS each refuse a navigation away from the app's document, and
     * each comment says why: a page that moves itself to a remote origin is
     * then the document holding the channel to the native window. This
     * driver subscribed to no navigation event at all, and the preload and
     * the app author's own page script go in through
     * AddScriptToExecuteOnDocumentCreated, which registers them on the view
     * rather than on a document -- so whatever the page navigated to was
     * handed both. Measured, against a target that answered:
     * nav_arrived=YES, after_nav api=object page=number.
     *
     * Three subscriptions, and ContentLoading is one of them because the
     * gate has to be armed from inside the engine. NavigationStarting fires
     * for this driver's own load -- twice, as about:blank and then as the
     * data: url NavigateToString makes -- so a policy that refuses what it
     * does not recognise refuses the app's own document, which is PR 6's
     * lesson arriving from the other direction.
     *
     * Partial is reported rather than silently accepted: a guard that got
     * two of three is a different build from one that got all three.
     */
    NeutrinoWebview.wireWebView2Navigation = function (SystemRef, coreWv2) {
        var wanted = [
            ["NavigationStarting", "navstart"],
            ["NewWindowRequested", "newwindow"],
            ["ContentLoading", "commit"]
        ];
        var wired = 0;
        for (var i = 0; i < wanted.length; i++) {
            try {
                var evt = coreWv2.GetType().GetEvent(wanted[i][0]);
                if (!evt) {
                    continue;
                }
                var sink = new NeutrinoNavSink();
                sink.kind = wanted[i][1];
                evt.AddEventHandler(coreWv2, SystemRef.Delegate.CreateDelegate(
                    evt.EventHandlerType, sink, sink.GetType().GetMethod("Handle")
                ));
                wired++;
            } catch (_) {
            }
        }
        if (wired < wanted.length) {
            this.note("navigation guard wired " + wired + " of " +
                wanted.length + " events; a navigation may not be refused here");
        }
        return wired === wanted.length;
    };

    /*
     * Whatever the guard refused, said out loud by the side of this file
     * that can say it. The decision itself is taken inside the handler --
     * Cancel and Handled are read the moment it returns -- so only the
     * telling is deferred to the loop.
     */
    NeutrinoWebview.drainNavRefusals = function (driver) {
        while (NeutrinoNavSink.refusals.Count > 0) {
            var text = String(NeutrinoNavSink.refusals[0]);
            NeutrinoNavSink.refusals.RemoveAt(0);
            this.note(text);
        }
        // The guard's other half, and the build check is here rather than in
        // the handler because this is the side of the file that can ask.
        // driver.openExternal asks again at the end of the line, which is
        // the same belt-and-braces every other lane has: one check where
        // the decision is made and one where the string becomes
        // ShellExecute.
        while (NeutrinoNavSink.externals.Count > 0) {
            var url = String(NeutrinoNavSink.externals[0]);
            NeutrinoNavSink.externals.RemoveAt(0);
            if (driver && driver.openExternal && this.mayOpenExternal(url)) {
                try {
                    driver.openExternal(url);
                } catch (e) {
                    this.noteOnce("could not open the refused window's url: " + e);
                }
            }
        }
    };

    // The event args carry both the text and who sent it. Source is the url
    // of the document that called postMessage, and the document this file
    // loads through NavigateToString has none worth the name -- so a
    // message from anywhere else is from a page that was navigated to.
    /*
     * What the view says it is showing, off the view and not off an event.
     *
     * Two things in the WebView2 loop need it and they used to be one, so
     * it lived inline: the turn that remembers the committed document, and
     * every title change judged against it. They have to be the same
     * reading -- remembering one and comparing another is a guard that
     * cannot pass -- and a function is how that stops being a thing to
     * remember. `null` is "the view would not say", which is refused rather
     * than trusted everywhere it reaches.
     */
    NeutrinoWebview.readWebView2Source = function (coreWv2, sourceProp) {
        if (!sourceProp) {
            return null;
        }
        try {
            return String(sourceProp.GetValue(coreWv2, null) || "");
        } catch (_) {
            return null;
        }
    };

    NeutrinoWebview.readWebView2Message = function (args) {
        var source = "";
        try {
            source = String(args.GetType().GetProperty("Source").GetValue(args, null) || "");
        } catch (_) {
            return null;
        }
        if (!this.isOwnDocument(source)) {
            return null;
        }
        try {
            return String(args.GetType().GetMethod("TryGetWebMessageAsString").Invoke(args, null));
        } catch (_) {
            return null;
        }
    };

