
    /*
     * The seatbelt profile, applied by the process it confines.
     *
     * macos-confine.sh builds the text and hands it over in the environment
     * rather than applying it with sandbox-exec, because a process that starts
     * confined cannot register with LaunchServices and therefore cannot show a
     * window. The paragraph in init says the rest.
     *
     * Cooperative, and it always was. This function is part of the artifact, so
     * an artifact that did not want to be confined has only ever had to ship
     * without it -- which was equally true of the sandbox-exec line this
     * replaces. The layer that does not depend on the artifact's cooperation is
     * netinstall's, applied by a binary the artifact does not write, and it is
     * untouched by this.
     *
     * sandbox_init_with_parameters is deprecated SPI with no header, so it is
     * bound by name out of libSystem. Measured: the bind succeeds, rc=0 applies
     * the profile, a write to $HOME afterwards is refused, and the activation
     * policy stays 0 -- a confined process that is still a real application.
     */
    NeutrinoWebview.confineMac = function (ObjCRef, dollar) {
        var profile = "";
        try {
            profile = String(ObjCRef.unwrap(
                dollar.NSProcessInfo.processInfo.environment
                    .objectForKey("NEUTRINO_MACOS_PROFILE")) || "");
        } catch (_) {}
        if (!profile) {
            /*
             * Nothing to apply. Either the shell said so already -- it prints
             * "could not build the seatbelt profile" and this is the same
             * launch -- or this lane was reached by something that is not
             * run_macos. Quiet rather than alarming, because the sentence that
             * matters was already said by whoever had the reason.
             */
            return false;
        }

        /*
         * Asked before it is attempted, and that ordering is the whole reason
         * this check exists rather than reading sandbox_init's answer.
         *
         * A process that is already confined cannot apply a second profile, and
         * a netinstall launch is exactly that: the downloader confines itself
         * with the same call and then execs this. sandbox_init answers -1 there
         * -- measured against a program built to netinstall's shape -- but
         * before it answers, libSystem writes "sandbox initialization failed:
         * Operation not permitted" to stderr on its own account. Nothing here
         * can catch that, so the only way not to print it on every download is
         * not to make the call.
         */
        if (this.macWritesConfined(ObjCRef, dollar)) {
            return true;
        }

        var rc = -1;
        try {
            ObjCRef.bindFunction("sandbox_init_with_parameters",
                ["int", ["string", "long long", "pointer", "pointer"]]);
            rc = dollar.sandbox_init_with_parameters(profile, 0, dollar(), dollar());
        } catch (e) {
            this.note("could not reach sandbox_init_with_parameters: " + e);
            return false;
        }
        if (rc === 0) {
            return true;
        }
        this.note("seatbelt refused this process's own profile; running unconfined");
        return false;
    };

    /*
     * Is a write outside this app's directory already refused?
     *
     * A measurement and not a marker: anything that can set an environment
     * variable could plant a marker, and the answer to "am I confined" would
     * then be forgeable by the one thing a confinement has to survive.
     *
     * access(2) through isWritableFileAtPath rather than an actual write,
     * because this runs on every launch and a launch should not leave a file
     * behind to answer a question about itself. Measured across all three
     * cases: true unconfined, false under a profile applied by sandbox-exec,
     * false under one applied in-process and inherited through exec.
     *
     * $HOME rather than a likelier path, because it is the one place this
     * profile's whole purpose is to keep an app out of -- and a $HOME that
     * refuses a write for its own reasons is a machine with larger problems
     * than this line.
     */
    NeutrinoWebview.macWritesConfined = function (ObjCRef, dollar) {
        try {
            var home = String(ObjCRef.unwrap(
                dollar.NSProcessInfo.processInfo.environment.objectForKey("HOME")));
            if (!home) {
                return false;
            }
            return !dollar.NSFileManager.defaultManager.isWritableFileAtPath(home);
        } catch (_) {
            return false;
        }
    };

    NeutrinoWebview.createMacDriver = function () {
        // JXA's two globals, named rather than eval'd -- see createGjsDriver
        // for the whole of why they used to be strings. Nothing else changes:
        // an engine that is not osascript parses these two lines and never
        // reaches them, exactly as before.
        var ObjCRef = ObjC;
        var dollar = $;
        var app;
        var self = this;
        var messageCallback = null;
        var webViewRef = null;
        var windowDelegateRef = null;
        var scriptHandlerRef = null;
        var navDelegateRef = null;
        // Whether init got the NSWindow subclass registered. Read by
        // createWindow, which is the only place that can act on it.
        var macKeyableWindow = false;
        var pendingPreload = null;
        var pendingPageScript = null;
        var documentLoaded = false;
        // The theme observer is an ObjC object with no arguments to its
        // selector, so what it needs to reach has to be here rather than
        // passed in. Both are null until the launch has got that far, and
        // the observer is not attached until it has.
        var driverRef = null;
        var windowRef = null;
        var observerRef = null;
        // Held for the same reason observerRef is: an NSTimer's target is
        // an object this script created, and nothing else refers to it.
        var tickerRef = null;
        // The status file's line 7, and the whole of what separates "the
        // window has stopped changing" from "the thing writing this file
        // has stopped". Both are in testing builds only.
        var statusTicks = 0;
        // The last title this lane read off the view. The clock below is a
        // poll and this is what makes it an edge: without it every tick
        // would set the window's title again, and writeStatus with it.
        var lastDocumentTitle = "";

        // What the view is showing, as the view answers rather than as
        // anything that called in claims. Empty is an answer too: a view
        // that will not say is one nothing may be trusted from.
        var currentUrl = function () {
            try {
                var u = webViewRef ? webViewRef.URL : null;
                return u ? String(ObjCRef.unwrap(u.absoluteString) || "") : "";
            } catch (_) {
                return "";
            }
        };

        return {
            webMessageTransport: "window.webkit.messageHandlers.neutrino.postMessage",
            transportName: "wkscriptmessage",
            init: function () {
                ObjCRef["import"]("Cocoa");
                ObjCRef["import"]("WebKit");
                app = dollar.NSApplication.sharedApplication;

                /*
                 * Register as an application, then confine this process, in
                 * that order and both before anything else in this file runs.
                 *
                 * The order is not a preference. AppKit registers a process
                 * through LaunchServices, and the profile this is about to
                 * apply denies com.apple.coreservices.launchservicesd -- which
                 * is half of what closes the write-a-bundle-and-launch-it
                 * escape, and is not negotiable. Under that denial
                 * setActivationPolicy(Regular) returns false and the process
                 * never enters the application list at all: measured from
                 * outside with NSRunningApplication, a confined launch does not
                 * appear in it, while the same artifact with no profile appears
                 * as policy=0. The app runs either way -- the window is
                 * created, WKWebView renders, the page's own probe reports
                 * `eng=WebKit ... bound=yes` -- and on screen there is nothing.
                 *
                 * So the profile arrives as text and is applied here, after the
                 * registration and before this driver reads a theme, opens a
                 * window or loads a line of the document. Everything the app
                 * itself can reach happens after this line.
                 *
                 * setActivationPolicy used to be called in runEventLoop, one
                 * line above app.run(). It is here now because that is after
                 * loadHTML, and a registration that happens after the profile
                 * is a registration that does not happen.
                 */
                try {
                    if (!dollar.NSApp.setActivationPolicy(0)) {
                        self.note("this process could not register as an " +
                            "application; its window will not appear");
                    }
                } catch (e) {
                    self.note("could not set the activation policy: " + e);
                }

                /*
                 * Finish the launch here, rather than letting app.run do it.
                 *
                 * -run calls finishLaunching itself, and that is the problem:
                 * run is the last line of runEventLoop, and showWindow --
                 * makeKeyAndOrderFront and then activateIgnoringOtherApps --
                 * is the line before runEventLoop in boot. So this process
                 * made itself frontmost while AppKit had not finished
                 * launching it and nothing was dequeuing events.
                 *
                 * Measured from outside with NSRunningApplication at 20ms,
                 * twelve launches of the published artifact, every one the
                 * same shape:
                 *
                 *   ~700ms   policy=0 active=false launched=false
                 *   ~1230ms  policy=0 active=true  launched=false
                 *   ~1560ms  policy=0 active=true  launched=true
                 *
                 * The middle line is three to four hundred milliseconds of a
                 * window on screen, in front, that no run loop is reading
                 * clicks for. It is also an activation asserted by a process
                 * that has not finished launching, which is the case
                 * activateIgnoringOtherApps: is free to decline under the
                 * cooperative activation macOS 14 deprecated it for: the
                 * window is ordered front either way, because ordering is the
                 * window server's and it always works, and the focus is not
                 * granted. What that looks like is a window that opens
                 * unfocused and takes an app switch to become clickable --
                 * intermittently, because whether the early activate sticks
                 * and whether anyone clicks inside those milliseconds are
                 * both timing.
                 *
                 * With this line the middle state does not occur: the app
                 * goes from active=false launched=false straight to
                 * active=true launched=true. Not the profile's doing, and
                 * checked that way -- the same three lines come out of the
                 * artifact run straight through osascript with no netinstall
                 * and no confinement at all.
                 *
                 * Below setActivationPolicy, because finishLaunching is a
                 * launch and an unregistered process has nothing to finish.
                 * Above confineMac for the reason the paragraph above gives
                 * for setActivationPolicy: it is AppKit talking to
                 * LaunchServices, and the profile denies that.
                 *
                 * Read and not called, by this file's rule for a
                 * zero-argument selector returning void. See the note beside
                 * app.run.
                 */
                try { app.finishLaunching; } catch (e) {
                    self.note("could not finish launching: " + e);
                }

                self.confineMac(ObjCRef, dollar);
                ObjCRef.registerSubclass({
                    name: "NeutrinoWindowDelegate",
                    superclass: "NSObject",
                    methods: {
                        "windowWillClose:": {
                            types: ["void", ["id"]],
                            implementation: function () {
                                try { app.terminate(null); } catch (_) {}
                            }
                        }
                    }
                });

                /*
                 * The one subclass here that is not an NSObject, and the
                 * only reason it exists: AppKit answers NO to both of these
                 * for a borderless window, so a window built with an empty
                 * style mask cannot become key and the web view inside it
                 * never sees a keystroke. There is no property to set and
                 * no flag to raise -- the answer is a method, so overriding
                 * it is the whole mechanism.
                 *
                 * Registered unconditionally rather than under the config,
                 * because a class that fails to register should say so on
                 * the launch that would have used it and not on some later
                 * one; `undecorated` decides which class createWindow
                 * allocates, not whether this one exists.
                 *
                 * Degraded and not fatal, by the rule createWebView's
                 * message channel already follows on this lane: a
                 * borderless window nothing can type into is inert, and a
                 * launch with no window at all says less. The note names
                 * the call that was missing.
                 */
                macKeyableWindow = false;
                try {
                    ObjCRef.registerSubclass({
                        name: "NeutrinoKeyableWindow",
                        superclass: "NSWindow",
                        methods: {
                            "canBecomeKeyWindow": {
                                types: ["bool", []],
                                implementation: function () { return true; }
                            },
                            "canBecomeMainWindow": {
                                types: ["bool", []],
                                implementation: function () { return true; }
                            }
                        }
                    });
                    macKeyableWindow = true;
                } catch (e) {
                    self.note("no keyable window subclass: " + e);
                }

                /*
                 * The theme watcher, and on this lane it has to be a real
                 * object: -run never returns, so there is no loop to
                 * re-read from the way the Windows driver has. A subclass
                 * with a selector is the same shape the two delegates
                 * either side of this use, and for the same reason -- the
                 * block-taking spellings of these APIs are the ones JXA
                 * cannot supply.
                 *
                 * Registered here and attached in runEventLoop, because
                 * what it reaches -- the driver, the window, the view --
                 * does not exist yet.
                 */
                try {
                    ObjCRef.registerSubclass({
                        name: "NeutrinoAppearanceObserver",
                        superclass: "NSObject",
                        methods: {
                            "desktopThemeChanged:": {
                                types: ["void", ["id"]],
                                implementation: function () {
                                    if (!driverRef) {
                                        return;
                                    }
                                    self.applyTheme(driverRef, windowRef, webViewRef,
                                        driverRef.readTheme());
                                }
                            }
                        }
                    });
                } catch (e) {
                    self.note("no theme watcher on this lane: " + e);
                }

                /*
                 * This lane's clock, in the same shape and for the same
                 * reason: -run never returns, so a clock here has to be an
                 * ObjC object with a selector, and NSTimer's block-taking
                 * spelling is one JXA cannot supply.
                 *
                 * It used to be registered only under a testing build,
                 * because writeStatus was all it did and writeStatus
                 * refuses to write in a release build. It now also carries
                 * the title hook, which every build needs, so the gate
                 * moved down into writeStatus alone -- where it already
                 * was.
                 *
                 * A clock and not a signal, on the one lane where that is a
                 * choice this file did not get to make. The hook the other
                 * four use is the engine's own title-changed notification;
                 * WKWebView's is KVO, whose observer selector takes a
                 * `void *` context, and the JXA bridge has no type string
                 * for a pointer -- a registered method whose types cannot
                 * name its last argument marshals whatever happens to be in
                 * the register. Two hundred milliseconds against a property
                 * read is the price of not writing that.
                 */
                try {
                    ObjCRef.registerSubclass({
                        name: "NeutrinoStatusTicker",
                        superclass: "NSObject",
                        methods: {
                            "tick:": {
                                types: ["void", ["id"]],
                                implementation: function () {
                                    if (driverRef) {
                                        driverRef.statusTick();
                                    }
                                }
                            }
                        }
                    });
                } catch (e) {
                    self.note("no clock on this lane: " + e);
                }

                /*
                 * A navigation guard, and deliberately not the one this
                 * looks like it should be.
                 *
                 * WKNavigationDelegate decides a navigation through
                 * -webView:decidePolicyForNavigationAction:decisionHandler:,
                 * whose third argument is a block, and JXA cannot call one.
                 * Implementing that selector here refuses nothing: it
                 * wedges every load in the view including the first.
                 * Measured -- with the selector registered, the policy
                 * callback fires once for this file's own document, six
                 * ways of calling the handler all throw, and the load never
                 * reaches didStartProvisionalNavigation at all. Naming the
                 * parameter @? or block instead does not help; it aborts
                 * the process on an uncaught NSException. All four
                 * spellings register cleanly, so nothing warns you. This
                 * comment is here because adding that selector is the
                 * obvious thing to try and it ships a window that never
                 * loads.
                 *
                 * What is left needs no block, and it is enough.
                 * didCommitNavigation: is the document this file loaded
                 * arriving, which is where the view this driver is allowed
                 * to hear from is remembered -- before the page script the
                 * engine injects at document end, exactly as gjs arms at
                 * COMMITTED. didStartProvisionalNavigation: is a navigation
                 * beginning, and -stopLoading refuses it. Measured against
                 * a page on loopback that really answers: without this the
                 * document went, the user scripts were reinjected into what
                 * arrived, and it spoke to the native window from an http
                 * origin; with it the navigation is abandoned and the app's
                 * own document is still the one there.
                 *
                 * It is later than a policy decision and that is the
                 * ceiling here, not an oversight: the request has already
                 * left. Nothing is handed to the desktop's URL handler on
                 * refusal either, unlike gjs and Qt -- opening a link the
                 * page chose is a feature this guard is not the place to
                 * add.
                 *
                 * -stopLoading is read and not called, and that is not a
                 * typo. JXA runs a zero-argument selector when the property
                 * is *read*: -stopLoading returns void, so the read stops
                 * the load and yields undefined, and a `()` after it throws
                 * having already had its effect. This shipped as
                 * `stopLoading()` from PR 6 until PR 23 -- refusing the
                 * navigation every time and logging "could not refuse
                 * navigation to ..." every time, which is why nobody
                 * noticed for four PRs. Measured, on the same artifact one
                 * line apart: with this line deleted the page takes the
                 * window, and with the read -- either spelling -- the app
                 * keeps its own document. The same rule reaches win.center
                 * in createWindow and app.run in runEventLoop, and both
                 * carry a note. test/navrefuse.sh asserts this one from
                 * both sides, because a guard that says it failed while
                 * succeeding and one that says it succeeded while failing
                 * read the same from any single lane.
                 */
                /*
                 * And the other half of a page trying to leave -- a link
                 * with a target, which is not a navigation of this view --
                 * is not handled on this lane, and this is what was
                 * measured rather than what was assumed.
                 *
                 * It is not a hole. WKUIDelegate.h: "If you do not
                 * implement this method, the web view will cancel the
                 * navigation." So the window is already refused. What the
                 * other four lanes add on top -- saying so, and handing the
                 * url to the desktop -- is what is missing here.
                 *
                 * The selector is not the one the essay below warns about,
                 * and that much worked. -webView:decidePolicyForNavigation-
                 * Action:decisionHandler: takes a block JXA cannot call;
                 * this one takes four objects and returns one:
                 *
                 *   - (nullable WKWebView *)webView:(WKWebView *)webView
                 *       createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
                 *       forNavigationAction:(WKNavigationAction *)navigationAction
                 *       windowFeatures:(WKWindowFeatures *)windowFeatures;
                 *
                 * Registered as NeutrinoUIDelegate and attached to the
                 * view's UIDelegate, it was called, and the url read
                 * cleanly off navigationAction.request.URL:
                 *
                 *   refused a new window for about:blank
                 *   returning nil for the refused window
                 *
                 * Both lines present, in that order, and then the process
                 * ends. No exception, no further output, and stdwin's OPEN,
                 * FS1 and CLOSE phases never observed -- three failures in a
                 * suite that was green. The second line was added precisely
                 * to split the two candidates, and it says the body ran to
                 * the end: what does not survive is the *return*.
                 *
                 * `return null` is the reason. JXA turns a JS null into
                 * NSNull rather than nil in an ObjC context -- it is the
                 * same conversion that was breaking the theme watcher in
                 * runEventLoop, where it raised "-[NSNull length]:
                 * unrecognized selector" -- so WebKit is handed an NSNull
                 * where a WKWebView or nil was promised, and sends it
                 * messages.
                 *
                 * Every method in this file returns void, and this was the
                 * first that would not. The spelling is now known and it is
                 * `$()`: a registerSubclass implementation with types
                 * ["id", []] returning `$()` hands back `[id nil]`, where
                 * returning `null` hands back `[id NSNull]`. Measured on
                 * macOS 26 / Darwin 25.6, apple silicon, on the same desk
                 * that fixed the theme watcher -- so the sentence this
                 * paragraph used to carry, that no such spelling was known
                 * and there was no macOS here to find one on, is retired.
                 *
                 * It is still not shipped, and that is now a scope answer
                 * rather than an unknown. The refusal works without the
                 * delegate: nothing opens a window this file did not ask
                 * for, and what is missing is the log line and the forward.
                 * Writing the delegate is a change with a suite behind it
                 * and not a return value to slot in, so it stays written
                 * down until it is done properly.
                 */

                try {
                ObjCRef.registerSubclass({
                    name: "NeutrinoNavDelegate",
                    superclass: "NSObject",
                    methods: {
                        "webView:didStartProvisionalNavigation:": {
                            types: ["void", ["id", "id"]],
                            implementation: function () {
                                var going = currentUrl();
                                // Until the first commit the only
                                // navigation in flight is the one this file
                                // started, which is the same reasoning the
                                // gjs guard is built on.
                                if (!documentLoaded || self.isTrustedView(going)) {
                                    return;
                                }
                                try {
                                    webViewRef.stopLoading;
                                    self.note("refused navigation to " + going);
                                } catch (e) {
                                    self.note("could not refuse navigation to " +
                                        going + ": " + e);
                                }
                            }
                        },
                        "webView:didCommitNavigation:": {
                            types: ["void", ["id", "id"]],
                            implementation: function () {
                                self.rememberTrustedView(currentUrl());
                                documentLoaded = true;
                            }
                        }
                    }
                });
                } catch (e) {
                    /*
                     * Loud, because everything downstream depends on it.
                     * With no delegate nothing is ever remembered, and the
                     * sender check no longer fails open -- so the window
                     * comes up and refuses its own app. That is inert
                     * rather than dangerous, which is the trade this driver
                     * makes everywhere, but only if it says so.
                     */
                    self.note("no navigation guard, and no message will be " +
                        "trusted: " + e);
                }

                /*
                 * A real message handler, replacing a timer that read
                 * document.title twenty times a second. The title was never
                 * a channel: it is a property of whatever document happens
                 * to be loaded, so any page in this webview -- including one
                 * it navigated to -- could set it and drive the native
                 * window. This has a sender attached to it, which is the
                 * thing the title could never have.
                 */
                try {
                ObjCRef.registerSubclass({
                    name: "NeutrinoScriptHandler",
                    superclass: "NSObject",
                    /*
                     * No protocols key. Declaring WKScriptMessageHandler
                     * here fails with "protocol does not exist": a protocol
                     * only exists as a runtime object if something in the
                     * process references it, and nothing in an osascript
                     * process does. Conformance is not what makes this
                     * work in any case -- the content controller sends the
                     * selector, and a class that implements it answers.
                     * NeutrinoWindowDelegate above is an NSWindowDelegate
                     * on exactly the same terms.
                     */
                    methods: {
                        "userContentController:didReceiveScriptMessage:": {
                            types: ["void", ["id", "id"]],
                            implementation: function (_, message) {
                                try {
                                    if (!messageCallback) {
                                        return;
                                    }
                                    self.trace("message handler fired");
                                    if (!self.isTrustedMacSender(ObjCRef, message, webViewRef)) {
                                        return;
                                    }
                                    messageCallback(ObjCRef.unwrap(message.body));
                                } catch (_) {}
                            }
                        }
                    }
                });
                } catch (e) {
                    self.note("could not register the message handler: " + e);
                }
            },
            readFile: function (path) {
                var data = dollar.NSData.dataWithContentsOfFile(path);
                if (!data) {
                    throw new Error("Could not read local document: " + path);
                }
                var nsStr = dollar.NSString.alloc.initWithDataEncoding(data, dollar.NSUTF8StringEncoding);
                if (!nsStr) {
                    throw new Error("Could not decode local document as UTF-8: " + path);
                }
                return ObjCRef.unwrap(nsStr);
            },
            getScriptPath: function () {
                return self.getMacScriptPath(ObjCRef, dollar);
            },
            readTheme: function () {
                return self.readMacTheme(ObjCRef, dollar);
            },
            /*
             * The desktop's fonts, read once, because once is all this lane
             * gets.
             *
             * **There is no watcher for this and none is wired below.**
             * macOS publishes no notification for a change of UI font --
             * the appearance notifications this driver already observes are
             * about colour, and delivering a `neutrino:fontchange` on one
             * would be a lie about what happened. The nearest setting that
             * moves type is the accessibility text size, which is per-app
             * and has no scripting interface a probe can reach, so there is
             * nothing to test a watcher against either.
             *
             * What the code must therefore not do is register an observer
             * on a notification that is not this one, or add a font poll to
             * the status ticker. This lane has already paid once for a
             * watcher that never fired and looked entirely correct in
             * review -- the NSNull object argument, silent for a whole
             * round -- and a watcher with no signal behind it is the same
             * defect written on purpose.
             */
            readFonts: function () {
                return self.readMacFonts(ObjCRef, dollar);
            },
            repaint: function (win, wv, background) {
                self.paintMacWindow(win, background);
                if (wv) {
                    self.paintMacView(wv, background);
                }
            },
            evaluate: function (wv, js) {
                // Before the commit there is no document of ours to
                // evaluate into, and the preload already carries the
                // snapshot, so nothing is lost by dropping this.
                if (!documentLoaded) {
                    return;
                }
                /*
                 * An empty function, and not a nil of any spelling. This
                 * line said `null` and the comment above it said that was a
                 * nil completion handler and the one thing JXA can do with
                 * a block parameter. Both halves were wrong, and measured
                 * against a real WKWebView with a committed document, one
                 * spelling per launch:
                 *
                 *   null            crash: TypeError: null is not an object
                 *   $()             crash: TypeError: undefined is not an object
                 *   function () {}  survived the completion
                 *
                 * JXA cannot express a nil block at all -- `null` arrives as
                 * NSNull and `$()` as something no less non-nil, and WebKit
                 * keeps whichever it is handed and calls it when the
                 * evaluation returns. What it *can* do is the thing the old
                 * comment said it could not: a JS function bridges to a
                 * block and is called correctly. So the handler is a real
                 * one that does nothing, which is what "nothing here needs
                 * the result" always meant.
                 *
                 * The crash was unreachable until this week and that is the
                 * only reason it is not an old bug report. This function
                 * returns early until the document commits, and the only
                 * caller afterwards is applyTheme delivering a *changed*
                 * theme -- which needs the theme watcher, which was dead for
                 * its own NSNull reason two functions down. Fixing the
                 * watcher is what first made this line run, and the first
                 * desktop flip that reached it took the whole process down.
                 */
                wv.evaluateJavaScriptCompletionHandler(js, function () {});
            },
            createWindow: function (config) {
                var frame = dollar.NSMakeRect(0, 0, config.width, config.height);
                /*
                 * NSBorderlessWindowMask is zero, so this is the mask with
                 * nothing in it rather than a mask with a bit cleared. The
                 * three names are still spelled out on the decorated side
                 * because they are the frame this launcher has always
                 * opened, and a reader should not have to know what a
                 * default mask contains to know what was asked for.
                 *
                 * The class is the other half. A borderless NSWindow that
                 * is a plain NSWindow cannot become key; if the subclass
                 * did not register, init has already said so, and this
                 * opens the window anyway rather than opening nothing.
                 */
                var mask = self.undecorated()
                    ? dollar.NSBorderlessWindowMask
                    : (dollar.NSTitledWindowMask | dollar.NSClosableWindowMask |
                       dollar.NSResizableWindowMask);
                var windowClass = (self.undecorated() && macKeyableWindow)
                    ? dollar.NeutrinoKeyableWindow
                    : dollar.NSWindow;
                var win = windowClass.alloc.initWithContentRectStyleMaskBackingDefer(
                    frame,
                    mask,
                    dollar.NSBackingStoreBuffered,
                    false
                );
                win.title = config.title;
                self.paintMacWindow(win, self.resolveBackground(self.theme));
                windowRef = win;
                // Read and not called, by the rule the navigation
                // guard's comment sets out. This was win.center(), which
                // centred the window and then threw into this catch on
                // every launch it ever made. Measured: deleting the line
                // moves the window, keeping it in either spelling does not.
                try { win.center; } catch (_) {}
                windowDelegateRef = dollar.NeutrinoWindowDelegate.alloc.init;
                win["delegate"] = windowDelegateRef;
                this.writeStatus(win);
                return win;
            },
            createWebView: function () {
                var frame = dollar.NSMakeRect(0, 0, 100, 100);
                var wkConfig = dollar.WKWebViewConfiguration.alloc.init;

                /*
                 * Every call in here goes through the ObjC bridge, and a
                 * bridge that does not expose one of them throws. Letting
                 * that propagate means no window at all, which is the least
                 * informative thing that can happen -- there is nothing on
                 * screen and nothing said. Degrading instead leaves a
                 * window with no channel into it, which is inert rather
                 * than dangerous, and says which call was missing.
                 */
                try {
                    var ucc = dollar.WKUserContentController.alloc.init;

                    if (messageCallback) {
                        scriptHandlerRef = dollar.NeutrinoScriptHandler.alloc.init;
                        ucc.addScriptMessageHandlerName(scriptHandlerRef, "neutrino");
                    }

                    // Both halves arrive through the engine, which is what
                    // lets the document forbid script of its own: the API at
                    // document start, the page's code once there is a
                    // document to run it against.
                    if (pendingPreload) {
                        ucc.addUserScript(
                            dollar.WKUserScript.alloc
                                .initWithSourceInjectionTimeForMainFrameOnly(
                                    pendingPreload, 0, true
                                )
                        );
                    }
                    if (pendingPageScript) {
                        ucc.addUserScript(
                            dollar.WKUserScript.alloc
                                .initWithSourceInjectionTimeForMainFrameOnly(
                                    pendingPageScript, 1, true
                                )
                        );
                    }

                    wkConfig.userContentController = ucc;
                    self.trace("message channel wired, preload " +
                        (pendingPreload ? "injected" : "MISSING"));
                } catch (e) {
                    self.note("no message channel: " + e);
                }

                var wv = dollar.WKWebView.alloc.initWithFrameConfiguration(frame, wkConfig);
                try { wv.allowsLinkPreview = false; } catch (_) {}
                self.paintMacView(wv, self.resolveBackground(self.theme));
                webViewRef = wv;
                // Bracket notation for the same reason createWindow uses it
                // on a window's delegate.
                try {
                    navDelegateRef = dollar.NeutrinoNavDelegate.alloc.init;
                    wv["navigationDelegate"] = navDelegateRef;
                } catch (e) {
                    self.note("no navigation guard on this view: " + e);
                }
                return wv;
            },

            injectPreload: function (_, js) {
                pendingPreload = js;
            },
            injectPageScript: function (js) {
                pendingPageScript = js;
            },
            /*
             * The one height the flip below is allowed to measure against,
             * and it is the primary display's -- the screen whose frame
             * origin is 0,0. Cocoa's global coordinate space grows upward
             * from that screen's bottom-left corner and the top-left space
             * every caller here speaks grows downward from its top-left, so
             * the two differ by that one screen's height and by nothing
             * else, whichever display a window is actually on.
             *
             * This was NSScreen.mainScreen, which is not the primary
             * display: it is the screen holding the window with keyboard
             * focus, so on a second monitor of a different height it
             * answered a number that has no part in this conversion, and
             * answered a different one as focus moved. Every window on this
             * machine is on the only screen there is, which is why both
             * spellings measure 1024 here and why nothing caught it.
             *
             * screens is documented never to be empty, and mainScreen is
             * kept as the fallback rather than letting the arithmetic go on
             * with undefined if it ever is.
             */
            primaryScreenHeight: function () {
                var screens = dollar.NSScreen.screens;
                if (screens && screens.count > 0) {
                    return screens.objectAtIndex(0).frame.size.height;
                }
                return dollar.NSScreen.mainScreen.frame.size.height;
            },
            toMacY: function (y, winHeight) {
                return this.primaryScreenHeight() - y - winHeight;
            },
            toTopLeftY: function (macY, winHeight) {
                return this.primaryScreenHeight() - macY - winHeight;
            },
            /*
             * Scaffolding for verify-macos.sh, which has no other way to
             * read a window's geometry back. It is not part of running an
             * app, so a release build does not write it anywhere.
             *
             * Seven lines now, and the last four are what makes this an
             * instrument rather than a receipt. The first three were only
             * ever written from inside setTitle, resize and move -- so they
             * report what this driver was *asked* to do, and a window moved
             * by anything else on the platform produced no write at all.
             * That is enough to check an IPC call landed and not enough to
             * ask what `window.resizeTo` or an assignment to
             * `document.title` did, because neither of those comes through
             * here. statusTick below calls this on a clock for exactly that
             * reason.
             *
             * It still reads NSWindow and never the DOM: `win.title` is the
             * title bar, `win.frame` is the frame the window server has.
             * That keeps it standing outside the document in the same way
             * xdotool stands outside it on X11 -- in the app's process, but
             * not the page's account of itself. A reading taken from the
             * document belongs in the title as a -SELF field, not in here.
             *
             * Line 7 is a counter and not a clock. A file that has stopped
             * being written and a window that has stopped changing are the
             * same three lines otherwise, and the difference between them
             * is `close()` working and the poller having died.
             *
             * It takes the window and not a title, and that is a repair.
             * `resize` and `move` have called this as
             * `writeStatus(String(win.title), win)` since they were
             * written, and on this bridge `String()` of an ObjC wrapper is
             * the wrapper's description -- `[id __NSCFString]` -- and not
             * the string. Nothing noticed for as long as a setTitle always
             * followed and overwrote it. Put a clock on the same function
             * and it writes that text over the good title several times a
             * second, which starved every suite on this platform that polls
             * this file: measured, five red steps and a lane that could not
             * say why. Every other reader of an ObjC string in this file
             * goes through unwrap, and now so does this one -- taking the
             * window rather than a title is what stops a fifth caller
             * getting it wrong again.
             */
            windowTitle: function (win) {
                try {
                    return String(ObjCRef.unwrap(win.title) || "");
                } catch (_) {
                    return "";
                }
            },
            writeStatus: function (win) {
                // A delegate, because the part that varies cannot be a method
                // of an object literal: an overlay replaces a file, and this
                // file is the whole macOS driver. A release build's
                // writeMacStatus is an empty function -- see js/macos-status.js.
                self.writeMacStatus(this, dollar, win);
            },

            /*
             * What the clock calls, and it has two jobs.
             *
             * The first is this lane's half of the title hook: the view's
             * `title` is WKWebView's own reading of the document it has
             * loaded, and comparing it against the last one accepted is
             * what turns a poll into an edge. The url comes from
             * currentUrl, which is the reader isTrustedMacSender already
             * uses, so the two sender checks on this lane cannot drift
             * apart.
             *
             * The second is writeStatus, which is scaffolding and gates
             * itself on whether this is a testing build. The title goes first so that a tick which
             * moves the window's name writes the file with the new name in
             * it rather than one tick behind -- setTitle writes it again on
             * the way past, and a second write of the same seven lines
             * costs nothing.
             */
            statusTick: function () {
                if (!windowRef) {
                    return;
                }
                try {
                    // The same rule the WebView2 loop follows, for the same
                    // reason: this is a poll, lastDocumentTitle is what makes
                    // it an edge, and latching a title before there is a
                    // document to judge it against would swallow that title
                    // for the rest of the run.
                    //
                    // hasCommittedDocument is one gate and acceptDocumentTitle
                    // is a second, and the latch used to sit between them --
                    // so a title refused by the second was latched as seen
                    // and never offered again. That is the same defect this
                    // comment was written about, one gate further down.
                    //
                    // Measured: `macos-stdwin` lost STD-WIN-OPEN-SELF in two
                    // rounds out of four. The probe calls
                    // open("ftp://neutrino.invalid/probe","_self"), which asks
                    // the engine to navigate this view, and acceptDocumentTitle
                    // refuses every title while the view is not showing the
                    // launcher's own document. The refusal is right and it is
                    // brief; the latch was what made it permanent, because the
                    // next read equalled the last and there was no edge left.
                    //
                    // So only an accepted title is latched. A refused one is
                    // re-judged on the next tick, which is what lets it land
                    // once the view is back on its own document -- the gate is
                    // a pure function of two reads and costs nothing to ask
                    // again, and noteOnce keeps a standing refusal quiet.
                    if (webViewRef && self.hasCommittedDocument()) {
                        var raw = "";
                        try {
                            raw = String(ObjCRef.unwrap(webViewRef.title) || "");
                        } catch (_) {
                            raw = "";
                        }
                        if (raw !== lastDocumentTitle) {
                            var name = self.acceptDocumentTitle(currentUrl(), raw);
                            if (name !== null) {
                                lastDocumentTitle = raw;
                                this.setTitle(windowRef, name);
                            }
                        }
                    }
                } catch (_) {}
                try { this.writeStatus(windowRef); } catch (_) {}
            },
            setTitle: function (win, title) {
                win.title = title;
                this.writeStatus(win);
            },
            resize: function (win, w, h) {
                var frame = win.frame;
                /*
                 * The top edge is held, not the origin, and it is held
                 * through the same two converters move and writeStatus use
                 * rather than by arithmetic of its own. AppKit measures a
                 * frame from its bottom-left corner, so reusing origin.y
                 * across a size change pins the bottom and lets the title
                 * bar fall by the difference -- which is a move, and the one
                 * move here nobody asked for.
                 *
                 * Measured on the published demo, which opens at the 900x600
                 * default and resizes itself to 520x300 once its page is
                 * ready: the window arrived at top-left 368,98 and 380 ms
                 * later a smaller window sat at 368,430. Same NSWindow, same
                 * window number -- but 332 px down the screen, retitled, and
                 * now carrying content it had none of before. It reads as
                 * the first window closing and a second one opening
                 * somewhere else, which is exactly what it was reported as.
                 *
                 * The other three drivers already hold the top-left, none of
                 * them by choosing to: Forms.ClientSize leaves Location
                 * alone, Gtk.resize leaves the position to the window
                 * manager, and a QML Window's x and y are its top-left.
                 * Cocoa's corner was the only one that leaked, and this
                 * driver had already decided not to speak it.
                 */
                var target = this.frameSizeForContent(win, w, h);
                var top = this.toTopLeftY(frame.origin.y, frame.size.height);
                win.setFrameDisplay(
                    dollar.NSMakeRect(frame.origin.x,
                        this.toMacY(top, target.height),
                        target.width, target.height), true);
                this.writeStatus(win);
            },

            /*
             * The content size a caller asked for, in the frame size AppKit
             * needs to produce it.
             *
             * This driver had already decided what a size means, at the one
             * place it opens a window:
             * `initWithContentRectStyleMaskBackingDefer` takes a **content**
             * rect, so `--size 900x600` gives a 900x600 web view inside a
             * frame 32 px taller. `resize` then set the frame to the numbers
             * it was handed, so one app asking for one size got two
             * different windows depending on when it asked -- 900x600 of
             * content at launch and 900x568 afterwards. Measured:
             * `resize(640,480)` produced `inner=640x448 outer=640x480`,
             * against `640x480` of content on all three other lanes.
             *
             * So this is not a change of definition, it is the resize path
             * catching up with the creation path beside it, and with Windows
             * (`ClientSize`), GTK (`gtk_window_resize`) and QML
             * (`root.width`/`height`), which all size content already.
             * Content is also the only definition a page can check for
             * itself: `innerWidth === w` after the call.
             *
             * `frameRectForContentRect:` is AppKit's own conversion and
             * accounts for the chrome this window actually has rather than a
             * constant this file would have to keep true. If the bridge
             * cannot answer, the current frame and content view give the
             * same difference by subtraction -- exact as long as the chrome
             * does not change between the two reads, which is the same
             * assumption the first route makes and states less openly. If
             * neither answers, sizing the frame is what this did for its
             * whole life and is better than refusing to resize.
             */
            frameSizeForContent: function (win, w, h) {
                try {
                    var r = win.frameRectForContentRect(dollar.NSMakeRect(0, 0, w, h));
                    var fw = Math.round(r.size.width);
                    var fh = Math.round(r.size.height);
                    if (fw > 0 && fh > 0) {
                        return { width: fw, height: fh };
                    }
                } catch (e) {
                    self.noteOnce("frameRectForContentRect did not answer: " + e);
                }
                try {
                    var frame = win.frame;
                    var cv = win.contentView.frame;
                    var dw = Math.round(frame.size.width - cv.size.width);
                    var dh = Math.round(frame.size.height - cv.size.height);
                    if (dw >= 0 && dh >= 0) {
                        return { width: w + dw, height: h + dh };
                    }
                } catch (e2) {
                    self.noteOnce("could not measure the window chrome: " + e2);
                }
                self.noteOnce("sizing the frame instead of the content; " +
                    "the chrome is unmeasurable on this window");
                return { width: w, height: h };
            },

            // The content size, by the same route writeStatus reads it --
            // the WKWebView is this window's contentView, so its frame is
            // what the page sees as innerWidth/innerHeight.
            contentSize: function (win) {
                try {
                    var cv = win.contentView.frame;
                    return {
                        width: Math.round(cv.size.width),
                        height: Math.round(cv.size.height)
                    };
                } catch (_) {
                    var f = win.frame;
                    return {
                        width: Math.round(f.size.width),
                        height: Math.round(f.size.height)
                    };
                }
            },
            move: function (win, x, y) {
                var frame = win.frame;
                var macY = this.toMacY(y, frame.size.height);
                win.setFrameDisplay(dollar.NSMakeRect(x, macY, frame.size.width, frame.size.height), true);
                this.writeStatus(win);
            },
            /*
             * Two units in one struct, on purpose: each half is in the units
             * of the verb that consumes it. `resizeBy` adds its delta to
             * `width`/`height` and hands the sum to `resize`, which now
             * speaks content; `moveBy` adds to `x`/`y` and hands the sum to
             * `move`, which speaks the frame's top-left. Reporting the frame
             * size here after `resize` switched to content would have made
             * every `resizeBy` on this lane wrong by the height of the title
             * bar, and wrong cumulatively -- each call shrinking the window
             * by the chrome it double-counted.
             */
            getBounds: function (win) {
                var f = win.frame;
                var size = this.contentSize(win);
                return {
                    width: size.width,
                    height: size.height,
                    x: Math.round(f.origin.x),
                    y: Math.round(this.toTopLeftY(f.origin.y, f.size.height))
                };
            },
            "close": function (win) {
                win.performClose(null);
            },
            openExternal: function (url) {
                if (!self.mayOpenExternal(url)) {
                    return;
                }
                dollar.NSWorkspace.sharedWorkspace.openURL(
                    dollar.NSURL.URLWithString(String(url))
                );
            },
            onWebMessage: function (cb) {
                messageCallback = cb;
            },
            attachWebView: function (win, wv) {
                win.contentView = wv;
            },
            loadHTML: function (wv, html, basePath) {
                var baseUrl = dollar.NSURL.fileURLWithPath(basePath).URLByDeletingLastPathComponent;
                self.trace("loading " + html.length + " bytes with base " + basePath);
                wv.loadHTMLStringBaseURL(html, baseUrl);
            },
            showWindow: function (win) {
                win.makeKeyAndOrderFront(null);
                try { app.activateIgnoringOtherApps(true); } catch (_) {}
            },
            runEventLoop: function () {
                /*
                 * Two notifications, and the second is not redundancy.
                 *
                 * AppleInterfaceThemeChangedNotification is the one that
                 * says the desktop switched, and it is known to arrive
                 * before NSColor has finished resolving to the new
                 * appearance -- so the palette read from it can be the old
                 * one. NSSystemColorsDidChangeNotification arrives when the
                 * colours themselves have changed, which is the event this
                 * actually cares about. Whichever is right, applyTheme's
                 * diff means the other one costs nothing: a second read
                 * returning the same palette is not an update.
                 *
                 * `dollar()` and not `null` for the object: argument, and
                 * this is the conversion the Method section warns about
                 * arriving somewhere it could be fixed. JXA turns a JS null
                 * into NSNull rather than nil, and both of these calls took
                 * it badly, in two different ways that look like one bug and
                 * are not:
                 *
                 *   - NSDistributedNotificationCenter sends -length to the
                 *     object, because a distributed notification's object
                 *     has to be a string. NSNull does not answer it, so the
                 *     call raised -- measured on macOS 26 / Darwin 25.6,
                 *     apple silicon:
                 *
                 *       no theme watcher on this lane: Error: exception
                 *       raised by object: -[NSNull length]: unrecognized
                 *       selector sent to instance
                 *
                 *     which the catch below turned into a note, and the
                 *     theme watcher was simply not attached from then on.
                 *   - NSNotificationCenter took the same NSNull without a
                 *     word and used it as the filter it is: an observer
                 *     registered for object NSNull matches notifications
                 *     posted with object NSNull, and nothing posts one. It
                 *     never raised and it never fired, which is the worse
                 *     of the two, because the note above was the only
                 *     evidence either existed. Measured with a local post
                 *     of the same name: object:null fired 0, object:$()
                 *     fired 1.
                 *
                 * `$()` is the spelling -- it evaluates to `[id nil]`, and
                 * the alias this file already keeps for `$` calls the same
                 * way. It is also the answer the Method section says is not
                 * known here for a *returned* nil: a registerSubclass
                 * implementation with types ["id", []] returning `$()`
                 * hands back nil and returning `null` hands back NSNull,
                 * measured the same afternoon. That one is written down
                 * rather than acted on, because nothing in this file
                 * returns id yet and the delegate that would is still not
                 * written.
                 */
                driverRef = this;
                try {
                    observerRef = dollar.NeutrinoAppearanceObserver.alloc.init;
                    dollar.NSDistributedNotificationCenter.defaultCenter
                        .addObserverSelectorNameObject(
                            observerRef, "desktopThemeChanged:",
                            "AppleInterfaceThemeChangedNotification", dollar());
                    dollar.NSNotificationCenter.defaultCenter
                        .addObserverSelectorNameObject(
                            observerRef, "desktopThemeChanged:",
                            "NSSystemColorsDidChangeNotification", dollar());
                } catch (e) {
                    self.note("no theme watcher on this lane: " + e);
                }
                /*
                 * Two hundred milliseconds, against a probe that holds each
                 * state for fifteen hundred. Seven turns inside the
                 * shortest thing being measured is the margin, and it is
                 * the number the verifier's own completeness control is
                 * checked against -- not a rate chosen for feeling about
                 * right.
                 */
                try {
                    tickerRef = dollar.NeutrinoStatusTicker.alloc.init;
                    dollar.NSTimer
                        .scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(
                            0.2, tickerRef, "tick:", null, true);
                } catch (e) {
                    self.note("could not start the clock on this lane: " + e);
                }
                // setActivationPolicy is not here any more: it moved to init,
                // which is the only place it can run before the seatbelt
                // profile does. See the paragraph beside it there.
                //
                // Left as a call on purpose. By the same rule, reading
                // `run` is what enters the event loop, and that does not
                // return -- so the `()` after it is code that has never run
                // and never can. Right by accident rather than wrong, and
                // this PR changed the two lines it measured breaking.
                app.run();
            }
        };
    };

