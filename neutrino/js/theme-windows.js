    /*
     * The Windows palette, and the one lane where half of it is this file's
     * choice rather than the system's answer.
     *
     * System.Drawing.SystemColors is the obvious read and it is only half
     * right: on Windows 10 and 11 those are still the **classic light**
     * values whatever the app theme is set to. Reading them alone reports a
     * light desktop on a dark one -- the same failure the macOS lane has,
     * arrived at from the other direction and with no appearance to set to
     * fix it.
     *
     * So the scheme comes from the registry, which is where Windows keeps
     * the answer, and a dark reading takes the four surface colours from
     * the constants below. Those are this file's, not the system's: there
     * is no API that reports them, and inventing them by inverting the
     * light ones would be worse -- a desktop nobody is running. They are
     * the values Explorer and WinUI use, so an app that follows them
     * matches what is next to it on screen.
     *
     * The accent pair is read from SystemColors in both schemes, because
     * COLOR_HIGHLIGHT does track the user's accent colour on Windows 10 and
     * later. That is the part the system will actually tell you.
     */
    NeutrinoWebview.windowsDarkSurfaces = "background:#202020,foreground:#ffffff," +
        "base:#2b2b2b,text:#ffffff,border:#3d3d3d";

    /*
     * Where that scheme is read from, and why the obvious spelling of it
     * was wrong for as long as it existed.
     *
     * `eval("Microsoft")` resolves nothing. The import block at the top of
     * the jsc region brings in `System` and five namespaces under it and
     * nothing else, so the name is not in scope, the read throws, and the
     * catch turns it into `true` -- a light desktop reported on a dark one.
     * Not an error and not empty, just wrong, and in exactly the direction
     * that paints a white app on a dark machine. Every runner this has
     * built on is light, so nothing that ran here could ever have caught
     * it; flipping the desktop is what did, and the tell was that
     * `prefers-color-scheme` followed the registry while every colour this
     * file reports stayed at its light value.
     *
     * The type is reached by name instead. `Registry` is in mscorlib, so
     * `System.Type.GetType` resolves it with no import to add, through the
     * `eval("System")` every other late-bound call here already uses, and
     * `GetValue` has one public static overload so `GetMethod` needs no
     * signature to pick it out. The same reflected shape the WebView2 calls
     * below are built from.
     */
    NeutrinoWebview.windowsAppsUseLightTheme = function () {
        try {
            var SystemRef = eval("System");
            var type = SystemRef.Type.GetType("Microsoft.Win32.Registry");
            if (!type) {
                this.noteOnce("no Microsoft.Win32.Registry in this runtime; " +
                    "taking the desktop for light");
                return true;
            }
            var method = type.GetMethod("GetValue");
            if (!method) {
                this.noteOnce("Microsoft.Win32.Registry carries no GetValue here; " +
                    "taking the desktop for light");
                return true;
            }
            var value = method.Invoke(null, [
                "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\" +
                    "CurrentVersion\\Themes\\Personalize",
                "AppsUseLightTheme", null]);
            // Absent is light, and that is Windows' own default rather than
            // a guess: the value is written when the setting is changed, so
            // a machine that has never been switched to dark does not carry
            // it at all.
            if (value === null || value === undefined) {
                this.noteOnce("no AppsUseLightTheme on this machine; " +
                    "taking Windows' own default of light");
                return true;
            }
            // Once per distinct value, so a flip leaves two lines and a
            // steady desktop leaves one. This is the reading the surface
            // override turns on, and it was unattributable while the only
            // record of it was the colour that came out the other end.
            this.noteOnce("AppsUseLightTheme=" + value);
            return Number(value) !== 0;
        } catch (e) {
            this.noteOnce("could not read the app theme setting: " + e);
            return true;
        }
    };

    NeutrinoWebview.readWindowsTheme = function (SystemRef) {
        var nt = this;
        // Through Convert rather than off the Byte directly, for the reason
        // makeWindowsColor gives about the other direction: JScript.NET
        // picks an overload from the types it is handed.
        var hexOf = function (color) {
            return nt.toHex({
                red: SystemRef.Convert.ToInt32(color.R) / 255,
                green: SystemRef.Convert.ToInt32(color.G) / 255,
                blue: SystemRef.Convert.ToInt32(color.B) / 255
            });
        };
        try {
            var system = SystemRef.Drawing.SystemColors;
            var raw = {
                source: "windows",
                background: hexOf(system.Control),
                foreground: hexOf(system.ControlText),
                base: hexOf(system.Window),
                text: hexOf(system.WindowText),
                accent: hexOf(system.Highlight),
                accentText: hexOf(system.HighlightText),
                border: hexOf(system.ControlDark)
            };
            if (!this.windowsAppsUseLightTheme()) {
                var overrides = String(this.windowsDarkSurfaces).split(",");
                for (var i = 0; i < overrides.length; i++) {
                    var cut = overrides[i].indexOf(":");
                    raw[overrides[i].substring(0, cut)] = overrides[i].substring(cut + 1);
                }
            }
            return raw;
        } catch (e) {
            this.noteOnce("could not read the desktop palette: " + e);
            return null;
        }
    };

    /*
     * And on Windows, where both surfaces take a System.Drawing.Color.
     *
     * The Form paints the moment it is shown. The WebView2 control paints
     * white until it has content, and DefaultBackgroundColor is the
     * supported way to say otherwise -- it is a property of the WinForms
     * control rather than of CoreWebView2, which matters here because
     * CoreWebView2 does not exist until the runtime has finished starting
     * and the window is on screen well before that.
     *
     * Reached by reflection because the type is loaded at run time and
     * cannot be named at compile time, and because the property is not in
     * every WebView2 version this may be running against. A control that
     * does not carry it keeps its white and the Form underneath is still
     * painted.
     */
    NeutrinoWebview.makeWindowsColor = function (SystemRef, background) {
        var rgb = this.parseColor(background);
        if (!rgb) {
            return null;
        }
        try {
            // Through Convert rather than by handing doubles to an
            // overload set: JScript.NET picks an overload from the types it
            // is given, and Math.round hands it a Number.
            return SystemRef.Drawing.Color.FromArgb(
                255,
                SystemRef.Convert.ToInt32(Math.round(rgb.red * 255)),
                SystemRef.Convert.ToInt32(Math.round(rgb.green * 255)),
                SystemRef.Convert.ToInt32(Math.round(rgb.blue * 255)));
        } catch (e) {
            this.note("could not read the background: " + e);
            return null;
        }
    };

    NeutrinoWebview.paintWindowsView = function (wv, color) {
        if (!color) {
            return false;
        }
        try {
            var prop = wv.GetType().GetProperty("DefaultBackgroundColor");
            if (!prop || !prop.CanWrite) {
                return false;
            }
            prop.SetValue(wv, color, null);
            return true;
        } catch (e) {
            return false;
        }
    };

