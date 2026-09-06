// SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
// SPDX-License-Identifier: ISC
//
// fontprobe-gtk.js - what GTK will tell a launcher about the desktop's fonts,
// and which signals move when the desktop's fonts move.
//
// PROBE. Nothing here is asserted and nothing reads it but a person. It exists
// to decide the shape of a `neutrino.fonts` delivery the way qtpalette.qml and
// the first theme round decided the palette's: by measuring, on every lane,
// before anything is designed around a guess.
//
// Run standalone rather than through a built artifact, for the reason
// qtpalette.qml is standalone: the question is what the *toolkit* answers, and
// putting a launcher between the toolkit and the reading only adds a thing that
// can be wrong. Driven by fontflip.sh, which takes a baseline, moves the
// desktop's font underneath it and puts it back.
//
// Usage: gjs fontprobe-gtk.js [watch-seconds]
//        cjs fontprobe-gtk.js [watch-seconds]
//
// Every line is prefixed FONTPROBE so one grep lifts the whole reading out of a
// job log that also carries a launcher's own noise.
//
// What this desk answered, before a runner has said anything -- Mint/Cinnamon,
// X11, GTK 3.24, one `font-name` write through fontflip.sh:
//
//   fired#1 style-updated                       gtk-font-name = OLD
//   fired#2 changed::font-name  gnome schema    gtk-font-name = OLD
//   fired#3 changed::font-name  cinnamon schema gtk-font-name = OLD
//   fired#4 notify::gtk-font-name               gtk-font-name = NEW
//   fired#5 style-updated                       gtk-font-name = NEW
//   fired#6 changed::font-name  mate schema     gtk-font-name = NEW
//
// Two things fall out of that order and both are about how a watcher has to be
// written rather than about which signal to pick.
//
// `style-updated` fires for a font change at all -- which is the signal the
// theme watcher is *already* connected to on this lane, so following the `ui`
// role may cost no new connection. But it fires twice, and the first time the
// toolkit still holds the old value. A watcher that re-read from the first
// firing would measure no change; it works anyway, because the second firing
// carries the new one and applyTheme's themesDiffer gate drops the first as a
// duplicate. That is the same gate that stops the palette's repaint feeding
// itself, doing a second job it was not designed for.
//
// And the GSettings `changed::` callbacks are ahead of the toolkit, not behind
// it. All three fired while GtkSettings still read the old font, so a lane that
// re-read GtkSettings from a GSettings callback would read stale every time.
// This is the KDE palette finding upside down -- there the palette landed
// before the flag and the advice was to read the palette; here the key lands
// before the toolkit and the advice is to read neither from the other's signal.
// `notify::gtk-font-name` is the only one of the three that carries the new
// value at the moment it fires, and it is a cause signal for exactly one key,
// so the honest pairing is the one the theme watcher already uses: the specific
// notify, plus style-updated, with a diff behind both.

imports.gi.versions.Gtk = "3.0";
const { Gtk, Gdk, Gio, GLib, Pango } = imports.gi;

const WATCH = parseInt(ARGV[0] || "0", 10) || 0;

function say(s) { printerr("FONTPROBE " + s); }

Gtk.init(null);

// ------------------------------------------------------------------ GtkSettings
//
// The one source every GTK desktop has. `gtk-font-name` is fed by XSettings on
// a desktop that runs a settings daemon and by settings.ini where nothing does,
// so it answers on a bare window manager as well as under GNOME -- which is
// what makes it the `ui` role's floor rather than one desktop's key.
const settings = Gtk.Settings.get_default();

function setting(name) {
    try { return String(settings[name]); } catch (e) { return "<threw:" + e + ">"; }
}

// ------------------------------------------------------------------------ Pango
//
// The parse, and the finding that removes a whole class of work: this does not
// need writing. A Pango font description is `FAMILY-LIST [STYLE-OPTIONS] [SIZE]`
// and the style options are unquoted words in the middle of it, so a launcher
// splitting on the last space would read `Ubuntu Medium 10` as the family
// "Ubuntu Medium" -- a family no fontconfig will match. from_string gets it
// right, and it is in both GTK lanes already.
//
// Measured on this desk before the round:
//
//   Ubuntu Medium 10               family=Ubuntu            weight=500
//   Noto Sans Semi-Bold Condensed 11  family="Noto Sans"    weight=600 stretch=condensed
//   Segoe UI Variable Text 9       family="Segoe UI Variable Text"  weight=400
//
// The last one is the control: `Text` is a word that looks like a style option
// and is not one, and from_string keeps it in the family.
function describe(str) {
    if (!str || str === "null") { return "<unset>"; }
    let d;
    try { d = Pango.FontDescription.from_string(String(str)); }
    catch (e) { return "<threw:" + e + ">"; }
    // Absolute sizes are device units and not points; a desktop that carries
    // one would make every pt->px conversion below a lie, so it is reported
    // rather than silently divided.
    return "family=" + JSON.stringify(d.get_family()) +
        " pt=" + (d.get_size() / Pango.SCALE) +
        " abs=" + d.get_size_is_absolute() +
        " weight=" + d.get_weight() +
        " style=" + d.get_style() +
        " stretch=" + d.get_stretch();
}

// -------------------------------------------------------------------- GSettings
//
// The three roles GtkSettings has no key for, and the reason this whole feature
// is worth having: a GNOME or Cinnamon desktop distinguishes a document face, a
// monospace face and a title bar face, and every other platform here collapses
// some of them. This is the rich end that decides what the normalized set can
// contain at all.
//
// Looked up through the schema source first, and that is not defensiveness.
// `Gio.Settings.new()` on a schema this machine does not carry calls g_error(),
// which **aborts the process** -- not an exception, nothing to catch, no line
// after it. A launcher that read GSettings without this check would take a
// working desktop's app down for the crime of running XFCE.
function schemaPresent(id) {
    try {
        const src = Gio.SettingsSchemaSource.get_default();
        return !!(src && src.lookup(id, true));
    } catch (e) { return false; }
}

function readSchema(id, keys) {
    if (!schemaPresent(id)) { say("schema " + id + " absent"); return null; }
    let s;
    try { s = new Gio.Settings({ schema_id: id }); }
    catch (e) { say("schema " + id + " would not open: " + e); return null; }
    const have = s.list_keys();
    for (const k of keys) {
        if (have.indexOf(k) < 0) { say("  " + id + " " + k + " = <no such key>"); continue; }
        // get_value and not get_string. Two of the keys below are not strings
        // -- text-scaling-factor is a double and titlebar-uses-system-font a
        // boolean -- and get_string on either raises a GLib CRITICAL, prints
        // an assertion failure into the log and returns null. Asking for the
        // variant asks the key what it is instead of telling it.
        const variant = s.get_value(k);
        const type = variant.get_type_string();
        const text = (type === "s") ? variant.get_string()[0] : variant.print(false);
        say("  " + id + " " + k + " <" + type + "> = " + JSON.stringify(text) +
            (type === "s" ? "   " + describe(text) : ""));
    }
    return s;
}

say("start runtime=" + (typeof imports.system !== "undefined" ? "gjs-family" : "?") +
    " gtk=" + Gtk.MAJOR_VERSION + "." + Gtk.MINOR_VERSION);

say("gtksettings gtk-font-name=" + JSON.stringify(setting("gtk_font_name")) +
    "   " + describe(setting("gtk_font_name")));
say("gtksettings gtk-xft-dpi=" + setting("gtk_xft_dpi") +
    " (" + (Number(setting("gtk_xft_dpi")) / 1024) + " dpi)" +
    " gtk-xft-antialias=" + setting("gtk_xft_antialias") +
    " gtk-xft-hinting=" + setting("gtk_xft_hinting"));

try {
    const screen = Gdk.Screen.get_default();
    const display = Gdk.Display.get_default();
    say("gdk resolution=" + (screen ? screen.get_resolution() : "?") +
        " scale=" + (display && display.get_monitor(0) ? display.get_monitor(0).get_scale_factor() : "?"));
} catch (e) { say("gdk <threw:" + e + ">"); }

// The four keys, from whichever of the three schema families this desktop
// carries. All three are read rather than the first one found: a Cinnamon box
// carries the GNOME schemas too, and which of the two GTK actually follows is
// the question -- themeflip.sh learned the same thing about gtk-theme, where
// the two schemas disagreed and only one of them moved the toolkit.
const INTERFACE_KEYS = ["font-name", "document-font-name", "monospace-font-name",
                        "text-scaling-factor"];
const WM_KEYS = ["titlebar-font", "titlebar-uses-system-font"];

const watched = [];
for (const id of ["org.gnome.desktop.interface", "org.cinnamon.desktop.interface",
                  "org.mate.interface"]) {
    const s = readSchema(id, INTERFACE_KEYS);
    if (s) { watched.push([id, s]); }
}
for (const id of ["org.gnome.desktop.wm.preferences",
                  "org.cinnamon.desktop.wm.preferences"]) {
    const s = readSchema(id, WM_KEYS);
    if (s) { watched.push([id, s]); }
}

if (WATCH <= 0) {
    say("done watch=0");
} else {
    // ------------------------------------------------------------------ the live half
    //
    // Which signal a launcher would have to connect to follow a font change,
    // and whether it needs to connect anything new at all.
    //
    // Measured on this desk before the round: a `font-name` write emitted
    // `notify::gtk-font-name` *and* `style-updated` on a realized window. The
    // second one is the signal the theme watcher is already connected to, so
    // the `ui` role may cost no new connection whatsoever -- which is the
    // performance answer for this lane, if it holds on a runner too.
    //
    // A window is created for style-updated to have something to fire on.
    //
    // Shown, and an OffscreenWindow so that showing it puts nothing on anyone's
    // display -- which is the whole reason that class exists. The first draft
    // called realize() instead, on the reasoning that a style signal is about
    // the widget and not about the mapping, and the reasoning was wrong: a
    // realized-not-shown window did not emit style-updated for a font change,
    // where a shown one with a WebKitWebView in it did on the same desk minutes
    // earlier. That difference is the instrument's, not the toolkit's, and a
    // probe that reported "style-updated does not fire" off the quieter of the
    // two would have sent the round looking for a watcher the lane already has.
    const win = new Gtk.OffscreenWindow();
    win.show_all();

    let fired = 0;
    const mark = function (what) {
        fired++;
        say("fired#" + fired + " " + what +
            " gtk-font-name=" + JSON.stringify(setting("gtk_font_name")) +
            " xft-dpi=" + setting("gtk_xft_dpi"));
    };

    settings.connect("notify::gtk-font-name", () => mark("notify::gtk-font-name"));
    settings.connect("notify::gtk-xft-dpi", () => mark("notify::gtk-xft-dpi"));
    win.connect("style-updated", () => mark("style-updated"));

    for (const [id, s] of watched) {
        for (const k of INTERFACE_KEYS.concat(WM_KEYS)) {
            if (s.list_keys().indexOf(k) < 0) { continue; }
            s.connect("changed::" + k, () => mark("changed::" + k + " on " + id));
        }
    }

    say("watching for " + WATCH + "s");
    GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, WATCH, () => {
        say("done watch=" + WATCH + " fired=" + fired);
        say("final gtk-font-name=" + JSON.stringify(setting("gtk_font_name")) +
            "   " + describe(setting("gtk_font_name")));
        Gtk.main_quit();
        return false;
    });
    Gtk.main();
}
