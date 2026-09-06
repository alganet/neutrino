    NeutrinoWebview.createGjsDriver = function () {
        // `imports` is gjs's own global and it is named rather than eval'd.
        // The eval was here because jsc.exe compiled this file and resolves
        // globals at compile time, so a bare `imports` was a compile error on
        // the one platform that has none. This file is else/ now and jsc.exe
        // does not read it. Every other engine that does read it parses this
        // line and never runs it, which is what it did with the eval too.
        var importsRef = imports;
        var Gtk, WebKit2, GLib, ByteArray, Gdk, Gio, Pango;
        // The GSettings objects this lane watches, held for the life of
        // the process. A Gio.Settings that is collected stops emitting,
        // so a watcher that did not keep a reference would connect, work
        // for as long as the collector left it alone, and then quietly
        // stop -- which is the shape of defect no suite here would catch.
        var fontSettings = [];
        var self = this;
        var messageCallback = null;
        var pendingPreload = null;
        var pendingPageScript = null;
        var documentLoaded = false;
        // The window the title hook writes to. boot creates the window
        // before the view, so this is set by the time createWebView
        // connects anything to it.
        var windowRef = null;
        // Declared here and assigned in createWebView, because the message
        // handler below closes over it and is registered before that runs.
        // `var` hoists, so this was never a reference error and the handler
        // cannot fire before the view exists -- but the declaration sitting
        // under its own use is what jsc reports as "might not be initialized",
        // and the ordering is worth stating rather than leaving to hoisting.
        var wv = null;

        /*
         * A schema this machine actually carries, or null.
         *
         * Through the schema source first, and this is not defensiveness:
         * `Gio.Settings.new()` on a schema that is not installed calls
         * `g_error()`, which **aborts the process**. Not an exception,
         * nothing to catch, no line after it. A launcher that read
         * GSettings without this check would take a working desktop's app
         * down for the crime of running XFCE.
         *
         * The opened object is kept in `fontSettings` because the watcher
         * connects to it and because a collected Gio.Settings stops
         * emitting.
         */
        var openSettings = function (id) {
            try {
                var source = Gio.SettingsSchemaSource.get_default();
                if (!source || !source.lookup(id, true)) {
                    return null;
                }
                var settings = new Gio.Settings({ schema_id: id });
                fontSettings[fontSettings.length] = settings;
                return settings;
            } catch (e) {
                self.noteOnce("could not open " + id + ": " + e);
                return null;
            }
        };

        /*
         * One key, or "" -- and a schema being present does not mean the
         * key is. Measured: Cinnamon's org.cinnamon.desktop.interface
         * carries `font-name` and neither `document-font-name` nor
         * `monospace-font-name`, so `list_keys` is the difference between
         * reading a Mint desktop and throwing on one.
         */
        var settingString = function (settings, key) {
            if (!settings || settings.list_keys().indexOf(key) < 0) {
                return "";
            }
            return String(settings.get_string(key) || "");
        };

        /*
         * `get_boolean` and not `get_string`, and the probe learned this
         * the loud way: asking a boolean key for a string prints a GLib
         * CRITICAL and returns null.
         */
        var settingBool = function (settings, key) {
            if (!settings || settings.list_keys().indexOf(key) < 0) {
                return false;
            }
            return !!settings.get_boolean(key);
        };

        var gatherFontStrings = function () {
            var gathered = { gtkFontName: "", names: {}, interface: {},
                             titlebar: "", titlebarSystem: false };
            var settings = Gtk.Settings.get_default();
            if (settings) {
                gathered.gtkFontName = String(settings.gtk_font_name || "");
            }
            var ids = String(self.gtkFontSchemas).split(",");
            var opened = {};
            var i;
            for (i = 0; i < ids.length; i++) {
                opened[ids[i]] = openSettings(ids[i]);
                var name = settingString(opened[ids[i]], "font-name");
                if (name !== "") {
                    gathered.names[ids[i]] = name;
                }
            }
            var chose = self.gtkFontSchemaChoice(gathered.gtkFontName, gathered.names);
            if (chose !== "" && opened[chose]) {
                var keys = String(self.gtkFontKeys).split(",");
                for (i = 0; i < keys.length; i++) {
                    gathered.interface[keys[i]] = settingString(opened[chose], keys[i]);
                }
            }
            var wmIds = String(self.gtkFontWmSchemas).split(",");
            for (i = 0; i < wmIds.length; i++) {
                var wm = openSettings(wmIds[i]);
                if (!wm) {
                    continue;
                }
                var titlebar = settingString(wm, "titlebar-font");
                if (titlebar === "") {
                    continue;
                }
                gathered.titlebar = titlebar;
                gathered.titlebarSystem = settingBool(wm, "titlebar-uses-system-font");
                break;
            }
            return gathered;
        };

        /*
         * Pango, on the five strings gtkChooseFontStrings picked. The
         * parse is the toolkit's own -- see gtkRoleFields for the three
         * measured cases a hand-written one gets wrong.
         *
         * An absolute size is in device units and is converted to points
         * here, so that what leaves this lane is points throughout and the
         * raw object carries one unit rather than one per role.
         */
        var parseFontStrings = function (chosen) {
            var roles = self.fontRoleList();
            var out = {};
            for (var i = 0; i < roles.length; i++) {
                var text = chosen[roles[i]];
                if (!text) {
                    continue;
                }
                var desc = Pango.FontDescription.from_string(String(text));
                var size = desc.get_size() / Pango.SCALE;
                if (desc.get_size_is_absolute()) {
                    size = size * 72 / 96;
                }
                out[roles[i]] = self.gtkRoleFields(roles[i], {
                    family: desc.get_family(),
                    size: size,
                    weight: desc.get_weight()
                });
            }
            return out;
        };

        return {
            webMessageTransport: "window.webkit.messageHandlers.neutrino.postMessage",
            transportName: "scriptmessage",
            init: function () {
                /*
                 * Only the typelib acquisition is inside this. Gtk.init
                 * below is deliberately outside it, because a display that
                 * will not open is not this lane being unavailable -- no
                 * other lane would fare better, and turning it into a
                 * fallthrough would replace "cannot open display" with a
                 * walk that tries everything and then reports that no
                 * runtime exists, which is both slower and untrue.
                 */
                try {
                    importsRef["gi"]["versions"]["Gtk"] = "3.0";
                    importsRef["gi"]["versions"]["WebKit2"] = self.resolveLinuxWebKitVersion();
                    Gtk = importsRef["gi"]["Gtk"];
                    WebKit2 = importsRef["gi"]["WebKit2"];
                    GLib = importsRef["gi"]["GLib"];
                    ByteArray = importsRef["byteArray"];
                    // Pinned to match Gtk rather than left to the loader.
                    // Gdk 3 and Gdk 4 are different libraries and only one
                    // of them belongs in a process running Gtk 3; the
                    // PyGObject lane pins it for the same reason and gets a
                    // warning on stderr when it does not.
                    importsRef["gi"]["versions"]["Gdk"] = "3.0";
                    Gdk = importsRef["gi"]["Gdk"];
                    // Pinned for the same reason Gdk is. Both come with
                    // GTK 3 on every desktop this runs on, so neither is a
                    // new dependency -- but an unpinned version is a
                    // loader's guess, and this lane has paid for one of
                    // those before.
                    importsRef["gi"]["versions"]["Pango"] = "1.0";
                    Gio = importsRef["gi"]["Gio"];
                    Pango = importsRef["gi"]["Pango"];
                } catch (e) {
                    if (e && e.neutrinoEngineUnavailable) {
                        throw e;
                    }
                    throw self.engineUnavailable(String(e && e.message ? e.message : e));
                }
                Gtk.init(null);

                /*
                 * WebKitGTK's own bubblewrap sandbox is opt-in, and until
                 * now neutrino never opted in -- so the process rendering
                 * whatever the page contains had nothing around it at all.
                 * This is the protection against hostile page content, and
                 * it is a different thing from netinstall's protection
                 * against the app's author.
                 *
                 * The two do not compose on Linux. netinstall's Landlock
                 * denies mount to any domain handling a filesystem right,
                 * and PR_SET_NO_NEW_PRIVS is required for Landlock, so
                 * under netinstall bubblewrap cannot initialise here. That
                 * trade is netinstall's README to explain; what this file
                 * can do is stop giving up the sandbox for nothing when it
                 * runs on its own, which is the normal case.
                 */
                /*
                 * WebKitGTK's sandbox is bubblewrap, and bubblewrap needs
                 * an unprivileged user namespace. Whether it can have one
                 * is not a property of this program: Ubuntu 24.04 and its
                 * derivatives set kernel.apparmor_restrict_unprivileged_-
                 * userns to 1 and refuse, while the same kernel version
                 * elsewhere allows it -- netinstall's README records the
                 * same split for the same reason, and its test suite has to
                 * lift that knob at all; what needed it is gone.
                 *
                 * It also does not degrade when it cannot start. The web
                 * process simply fails and the window comes up empty, which
                 * is a worse outcome than not having asked. And it cannot
                 * be probed honestly beforehand: the helper is resolved by
                 * an absolute path compiled into WebKitGTK, so looking for
                 * it on PATH answers a different question than the one
                 * being asked.
                 *
                 * So it is asked for, and taken back if it does not arrive.
                 * That covers every reason it might not -- a missing
                 * helper, a refused namespace, a seccomp filter in front of
                 * clone -- rather than the one reason a probe could name.
                 */
                if (GLib.getenv("NEUTRINO_WEBKIT_SANDBOX") === "1") {
                    try {
                        WebKit2.WebContext.get_default().set_sandbox_enabled(true);
                    } catch (e) {
                        self.note("webkit sandbox unavailable: " + e);
                    }
                } else {
                    self.note("webkit sandbox off: this system refused a user namespace");
                }
            },
            readFile: function (path) {
                var result = GLib.file_get_contents(path);
                if (!result[0]) {
                    throw new Error("Could not read local document: " + path);
                }
                return ByteArray.toString(result[1]);
            },
            getScriptPath: function () {
                return self.getLinuxScriptPath(importsRef);
            },
            /*
             * Off a Gtk.Box, which is a widget and not a window: this is
             * asked before createWindow, and the names being looked up are
             * the theme's rather than any widget's -- measured identical on
             * Box, Label and Window. Building a toplevel just to read a
             * colour would be a second window in a launcher whose whole
             * point is the first one.
             */
            readTheme: function () {
                try {
                    return self.readGtkTheme(new Gtk.Box().get_style_context());
                } catch (e) {
                    self.noteOnce("could not read the desktop theme: " + e);
                    return null;
                }
            },
            /*
             * The desktop's fonts. Every decision is in else/font-gtk.js;
             * what is here is the two halves that need a runtime -- the
             * GSettings walk and the Pango parse -- and the PyGObject lane
             * writes the same two in Python against the same shared
             * functions.
             */
            readFonts: function () {
                try {
                    var gathered = gatherFontStrings();
                    var chosen = self.gtkChooseFontStrings(gathered);
                    return self.gtkFontsFromParsed(parseFontStrings(chosen));
                } catch (e) {
                    self.noteOnce("could not read the desktop fonts: " + e);
                    return null;
                }
            },
            createWindow: function (config) {
                // A construct property and not a set_decorated call after
                // the fact: GTK maps the decoration request onto the window
                // before it is realised, and a toplevel that is decorated
                // and then undecorated is one the window manager has
                // already framed once.
                var win = new Gtk.Window({
                    title: config.title,
                    default_width: config.width,
                    default_height: config.height,
                    decorated: !self.undecorated()
                });
                windowRef = win;
                win.set_position(Gtk.WindowPosition.CENTER);
                win.connect("destroy", function () { Gtk.main_quit(); });
                self.paintGtkWindow(Gtk, Gdk, win, self.resolveBackground(self.theme));
                return win;
            },
            /*
             * The scheme, on the toolkit's flag rather than on anything the
             * document can reach: CSS `color-scheme` was measured against
             * this engine first and moves nothing -- `:root{color-scheme:
             * dark}` in the markup, the same declaration through CSSOM, and
             * a `<meta name=color-scheme>` all left `prefers-color-scheme`
             * where it was. There is no in-page spelling of this.
             *
             * The default settings object and not the widget's, because
             * this runs before there is a widget -- boot forces the scheme
             * between reading the palette and creating the window. Both
             * resolve to the same GtkSettings for the default screen, and
             * only one of them exists at that moment.
             *
             * Read before it is written, and not for the write's sake:
             * GTK emits the settings change whether or not the value moved,
             * and once there is a window the style-updated handler is
             * listening for exactly that. applyTheme's themesDiffer gate is
             * what stops the second pass, so asking first is the difference
             * between never entering that path and entering it once.
             */
            forceScheme: function (theme) {
                if (!self.gtkPreferDark(theme)) {
                    return;
                }
                var settings = Gtk.Settings.get_default();
                if (!settings) {
                    return;
                }
                if (settings.gtk_application_prefer_dark_theme) {
                    return;
                }
                settings.gtk_application_prefer_dark_theme = true;
            },
            // Both surfaces again, from the colour the new palette resolves
            // to. Only ever reached for a build that named no background --
            // applyTheme holds that gate, not this.
            repaint: function (win, wv, background) {
                self.paintGtkWindow(Gtk, Gdk, win, background);
                if (wv) {
                    self.paintWebKitView(Gdk, wv, background);
                }
            },
            evaluate: function (wv, js) {
                // The same gate the navigation guard arms at, and for a
                // near reason: before the commit there is no document of
                // ours to evaluate into, and a theme change during the
                // launch would otherwise be delivered to about:blank and
                // lost. The palette is in the preload, so nothing is
                // missing -- the page starts with whatever this would have
                // told it.
                if (!documentLoaded) {
                    return;
                }
                // run_javascript and not evaluate_javascript: this lane
                // resolves WebKit2 to 4.1 or 4.0 and only the first has the
                // newer spelling. Deprecated in 4.1, present in both.
                //
                // Three arguments and not four. The C function takes a
                // user_data alongside the callback and gjs drops it, so the
                // fourth was one this binding never had:
                //
                //   JS WARNING: Too many arguments to method
                //   WebKit2.WebView.run_javascript: expected 3, got 4
                //
                // It warned on every delivery and never on a launch, which
                // is why it went unseen for so long -- the only caller is a
                // theme change, and until the settings watcher below existed
                // this lane's watcher never fired on the desk it was written
                // at. The PyGObject shim passes four because PyGObject keeps
                // the user_data that gjs drops; the two spellings are both
                // right for their binding.
                wv.run_javascript(js, null, null);
            },
            createWebView: function () {
                var ucm = new WebKit2.UserContentManager();

                /*
                 * This lane's half of the title hook. `notify::title` is
                 * GObject's own signal on the view's own property, so it
                 * fires for a `<title>` the parser met and for an
                 * assignment the page made alike, and what is read back is
                 * WebKit's answer rather than anything the page handed
                 * over.
                 *
                 * The uri is read off the view and not off the event, the
                 * same way the message handler below reads it, so the two
                 * sender checks on this lane cannot drift apart.
                 */
                var titleWatcher = function (view) {
                    if (!windowRef) {
                        return;
                    }
                    var showing = "";
                    try {
                        showing = String(view.get_uri());
                    } catch (_) {
                        showing = "";
                    }
                    var name = self.acceptDocumentTitle(showing, view.get_title());
                    if (name !== null) {
                        windowRef.set_title(name);
                    }
                };

                if (messageCallback) {
                    ucm.register_script_message_handler("neutrino");
                    ucm.connect("script-message-received::neutrino", function (_, result) {
                        // The sender check. This handler is registered on
                        // the content manager, not on a document, so it
                        // hears from whatever the view is showing -- which
                        // is the question, and the one thing a message
                        // cannot lie about.
                        var showing = "";
                        try {
                            showing = String(wv.get_uri());
                        } catch (_) {
                            showing = "";
                        }
                        if (!self.isTrustedView(showing)) {
                            self.note("refused a message from " + showing);
                            return;
                        }
                        messageCallback(result.get_js_value().to_string());
                    });
                }

                // Both halves go in through the engine now: the API first,
                // at document start, then the page's own code once there is
                // a document to run it against.
                var inject = function (source, when) {
                    if (!source) {
                        return;
                    }
                    try {
                        ucm.add_script(WebKit2.UserScript["new"](
                            source,
                            WebKit2.UserContentInjectedFrames.TOP_FRAME,
                            when,
                            null,
                            null
                        ));
                    } catch (e) {
                        self.note("could not inject: " + e);
                    }
                };
                inject(pendingPreload, WebKit2.UserScriptInjectionTime.START);
                inject(pendingPageScript, WebKit2.UserScriptInjectionTime.END);

                wv = new WebKit2.WebView({ user_content_manager: ucm });
                self.paintWebKitView(Gdk, wv, self.resolveBackground(self.theme));
                /*
                 * COMMITTED, not FINISHED, and the difference is a hole.
                 *
                 * The author's script is injected at DOCUMENT_END, which
                 * runs after the document is committed and before its load
                 * has finished -- measured. A navigation started from there
                 * used to be decided while documentLoaded was still false,
                 * which is to say allowed. It looked closed on a document
                 * with nothing to fetch, because WebKitGTK delivers a policy
                 * decision on a later turn of the main loop and the load
                 * finished first and armed the guard in between. That is a
                 * race, and the page picks the winner: a stylesheet on a
                 * socket that never answers holds the load open for as long
                 * as it likes. Measured both ways -- allowed with the load
                 * held, refused once this armed at commit instead.
                 *
                 * The document the view committed is remembered here for
                 * the same reason: this is the load this file started, and
                 * nothing the page does has run yet.
                 */
                wv.connect("load-changed", function (_, loadEvent) {
                    if (loadEvent === WebKit2.LoadEvent.COMMITTED) {
                        documentLoaded = true;
                        try {
                            self.rememberTrustedView(wv.get_uri());
                        } catch (_) {}
                    }
                });

                var settings = wv.get_settings();
                try {
                    settings.set_enable_developer_extras(false);
                    settings.set_allow_file_access_from_file_urls(false);
                    settings.set_allow_universal_access_from_file_urls(false);
                    settings.set_javascript_can_access_clipboard(false);
                    settings.set_enable_write_console_messages_to_stdout(false);
                } catch (_) {}

                /*
                 * The document is loaded once, from this file, and never
                 * navigates again. Without this a link or a location
                 * assignment could replace it with a remote origin, and
                 * that origin would then be holding the channel to the
                 * native window -- the preload is registered on the user
                 * content manager, so it would be reinjected into whatever
                 * document arrived next.
                 */
                var driverRef = this;
                wv.connect("decide-policy", function (_, decision, decisionType) {
                    var types = WebKit2.PolicyDecisionType;
                    if (decisionType !== types.NAVIGATION_ACTION &&
                        decisionType !== types.NEW_WINDOW_ACTION) {
                        return false;
                    }
                    var uri = "";
                    try {
                        uri = String(decision.get_navigation_action().get_request().get_uri());
                    } catch (_) {
                        uri = "";
                    }
                    // Until the first document is committed, the only
                    // navigation in flight is the one this file started --
                    // measured: its decision is taken before any load event
                    // fires at all, so this is false when it matters.
                    // Keying on that rather than only on the url means an
                    // engine that spells the initial load differently
                    // cannot lock the app out of its own document.
                    if (!documentLoaded || self.isOwnDocument(uri)) {
                        return false;
                    }
                    decision.ignore();
                    self.note("refused navigation to " + uri);
                    driverRef.openExternal(uri);
                    return true;
                });
                wv.connect("notify::title", titleWatcher);
                return wv;
            },
            resize: function (win, w, h) {
                win.resize(w, h);
            },
            move: function (win, x, y) {
                win.move(x, y);
            },
            // The units this driver's own resize and move speak, so the
            // relative verbs above compose with them exactly.
            getBounds: function (win) {
                var size = win.get_size();
                var pos = win.get_position();
                return { width: size[0], height: size[1], x: pos[0], y: pos[1] };
            },
            openExternal: function (url) {
                // Checked here as well as in the splitter: this is the end
                // of the line, and it hands a string to the desktop's URI
                // handler, which will happily act on file: or on a .desktop
                // entry if it is given one. It is also where the navigation
                // refusal above arrives, so the build half of the check
                // closes that route as well as this one.
                if (!self.mayOpenExternal(url)) {
                    return;
                }
                try {
                    var Gio = importsRef["gi"]["Gio"];
                    Gio.AppInfo.launch_default_for_uri(String(url), null);
                } catch (_) {
                    // An argv, never a command line. The old fallback built
                    // "xdg-open " + url and handed it to a function that
                    // word-splits, so a url containing a space became two
                    // arguments and a url containing a quote became
                    // something else entirely.
                    try {
                        GLib.spawn_async(
                            null,
                            ["xdg-open", String(url)],
                            null,
                            GLib.SpawnFlags.SEARCH_PATH,
                            null
                        );
                    } catch (_) {}
                }
            },
            "close": function (win) {
                win.destroy();
            },
            onWebMessage: function (cb) {
                messageCallback = cb;
            },
            injectPreload: function (_, js) {
                pendingPreload = js;
            },
            injectPageScript: function (js) {
                pendingPageScript = js;
            },
            attachWebView: function (win, wv) {
                win.add(wv);
            },
            loadHTML: function (wv, html) {
                wv.load_html(html, null);
            },
            showWindow: function (win) {
                win.show_all();
            },
            runEventLoop: function (win, wv) {
                // `this` is the driver: boot calls every one of these as
                // driver.runEventLoop(...), which is also how applyTheme
                // gets back to repaint and evaluate below.
                var driver = this;
                /*
                 * `style-updated` on the window, which GTK emits when the
                 * style context behind that widget changes -- a new theme
                 * name, a dark-preference flip, a provider added.
                 *
                 * This comment used to say it was the signal for the thing
                 * being reported rather than for one of the settings that
                 * can cause it, so that a desktop changing its colours some
                 * way nobody anticipated still arrived. That was wrong, and
                 * the word doing the damage is *that widget*: the signal is
                 * about the widget's own computed style and not about the
                 * theme. A change that leaves this window drawing itself
                 * identically is a change GTK has no reason to mention,
                 * however much of the palette moved underneath it.
                 *
                 * Measured on Mint 22 / Cinnamon / GTK 3.24, one window and
                 * three instruments watching the same five theme changes:
                 *
                 *   notify::gtk-theme-name   5 of 5
                 *   style-updated            2 of 5
                 *   polling lookup_color     5 of 5
                 *
                 * The three it missed are `Mint-L-Dark` to `-Aqua` to
                 * `-Red` to `-Blue`, which are this desktop's accent
                 * picker: same canvas, same derived scheme, and
                 * `theme_selected_bg_color` moving 8fa876 -> 6aa0bd ->
                 * b35a57 -> 596eb5 the whole time. The window's own
                 * background is identical across all four, so it restyled
                 * to the same thing and GTK said nothing. The two it caught
                 * both crossed theme families, where the canvas does move.
                 *
                 * Which is also why applyTheme's diff is not optional:
                 * repainting the window adds a CssProvider to it, and that
                 * emits this. Without the diff the first theme change would
                 * be the last thing this process ever did.
                 */
                try {
                    win.connect("style-updated", function () {
                        self.applyTheme(driver, win, wv, driver.readTheme());
                        /*
                         * The fonts ride this signal, because it fires for
                         * a font change too and is already connected.
                         *
                         * Measured, one `font-name` write, six firings in
                         * this order:
                         *
                         *   style-updated               gtk-font-name OLD
                         *   changed::font-name  gnome   gtk-font-name OLD
                         *   changed::font-name  cinn    gtk-font-name OLD
                         *   notify::gtk-font-name       gtk-font-name NEW
                         *   style-updated               gtk-font-name NEW
                         *   changed::font-name  mate    gtk-font-name NEW
                         *
                         * So this handler runs twice and the first time
                         * GtkSettings still holds the old value. That is
                         * harmless rather than lucky: fontsDiffer drops the
                         * first as a duplicate and the second carries the
                         * new one -- the same gate that stops the palette's
                         * repaint feeding itself, doing a second job it was
                         * not built for.
                         */
                        self.applyFonts(driver, wv, driver.readFonts());
                    });
                } catch (e) {
                    self.note("no theme watcher on this lane: " + e);
                }
                /*
                 * And the setting behind it, which is the half the signal
                 * above cannot see.
                 *
                 * `gtk-theme-name` on GtkSettings fired for every one of
                 * the five, with the new palette already readable off a
                 * style context by the time it did -- so this needs no
                 * delay and no second read. It is a *cause* signal, which
                 * is the thing the comment above wrongly claimed not to
                 * need: it catches a theme being renamed and nothing else.
                 * A desktop that recolours within one theme name -- which
                 * is what libadwaita's accent-color does on GNOME 47 and
                 * later -- still arrives here only if the window's own
                 * style moved. The XDG appearance portal is the answer to
                 * that one and is a larger change than this.
                 *
                 * Both are connected because neither is a superset of the
                 * other, and connecting both costs nothing: applyTheme
                 * drops an update that changed no colour, so the pair
                 * firing together is one delivery.
                 */
                try {
                    var settings = Gtk.Settings.get_default();
                    if (settings) {
                        settings.connect("notify::gtk-theme-name", function () {
                            self.applyTheme(driver, win, wv, driver.readTheme());
                        });
                        /*
                         * And the font's own cause signal, which is the one
                         * of the six above that carries the new value at
                         * the moment it fires.
                         *
                         * `applyFonts` and not `applyTheme` beside it: a
                         * font change is not a palette change, and pairing
                         * them would buy a style-context read on every one
                         * for no measured reason.
                         */
                        settings.connect("notify::gtk-font-name", function () {
                            self.applyFonts(driver, wv, driver.readFonts());
                        });
                    }
                } catch (eT) {
                    self.note("no settings watcher on this lane: " + eT);
                }
                /*
                 * And the three roles GtkSettings has no key for.
                 *
                 * Measured on a desk with a settings daemon running, one
                 * flip per row, each with the other paths silenced:
                 *
                 *   only changed::        ui did not arrive, monospace did
                 *   changed:: silenced    both arrived
                 *
                 * So `style-updated` carries a GSettings-only font change
                 * *here*, because the daemon that writes the key also
                 * touches something this window's style notices, and
                 * readFonts re-reads GSettings from scratch every time.
                 * These connections are redundant on such a desktop.
                 *
                 * They are not redundant everywhere, and that is why they
                 * stay. A machine with no settings daemon -- this suite's
                 * own runner -- never propagates a GSettings write to GTK
                 * at all: `gtk-font-name` was measured holding "Sans 10"
                 * through a `font-name` write that GNOME's key took. On
                 * such a desktop nothing but these callbacks can see the
                 * three roles GtkSettings has no key for.
                 *
                 * Neither signal is a superset of the other, which is the
                 * same reason the palette watcher above connects two, and
                 * connecting both costs nothing: fontsDiffer drops whichever
                 * arrives second.
                 *
                 * The stale-read hazard the order above records does not
                 * apply to them. It is `gtk-font-name` that is behind its
                 * own GSettings key, and readFonts takes that from
                 * GtkSettings; each of these keys is authoritative for
                 * itself and is current in its own callback.
                 *
                 * `fontSettings` is walked rather than reopened, because
                 * these are the objects readFonts already holds -- and
                 * holding them is what keeps them emitting at all.
                 */
                try {
                    var watched = String(self.gtkFontKeys).split(",")
                        .concat(String(self.gtkFontWmKeys).split(","));
                    for (var fi = 0; fi < fontSettings.length; fi++) {
                        for (var ki = 0; ki < watched.length; ki++) {
                            if (watched[ki] === "font-name" ||
                                fontSettings[fi].list_keys().indexOf(watched[ki]) < 0) {
                                continue;
                            }
                            fontSettings[fi].connect("changed::" + watched[ki], function () {
                                self.applyFonts(driver, wv, driver.readFonts());
                            });
                        }
                    }
                } catch (eF) {
                    self.note("no font-settings watcher on this lane: " + eF);
                }
                Gtk.main();
            }
        };
    };

    /*
     * Moved here from js/run.js with the rest of the lane. It reached the
     * runtime's own `imports` through eval because the file it lived in was
     * compiled by jsc.exe, which has no such global; this branch is not, so
     * the name is written down.
     */
    NeutrinoWebview.resolveLinuxWebKitVersion = function () {
        var GIRepository = imports.gi.GIRepository;
        var Repository = GIRepository["Repository"];
        var repository = Repository["dup_default"]
            ? Repository["dup_default"]()
            : Repository["get_default"]();
        var versions = repository.enumerate_versions("WebKit2");

        if (versions.indexOf("4.1") !== -1) {
            return "4.1";
        }
        if (versions.indexOf("4.0") !== -1) {
            return "4.0";
        }
        throw this.engineUnavailable("WebKit2 introspection typelibs not found");
    };
