# The shim. Every policy question in here is asked of the JavaScript this file
# was cut from; nothing in it decides anything on its own.
import json
import os
import sys

NOENGINE = 69


def unavailable(what):
    # Not a traceback. This is the one failure the launcher is waiting to hear
    # about, and it has another lane to try -- so it is one line and a status,
    # not a page of stack that reads like a crash to whoever ran the app.
    sys.stderr.write("neutrino: pygobject lane unavailable: %s\n" % (what,))
    sys.exit(NOENGINE)


try:
    import gi
except Exception as exc:
    unavailable("no PyGObject (%s)" % (exc,))

# 4.1 before 4.0, which is resolveLinuxWebKitVersion's order and has to stay
# that way: a machine carrying both must land on the same one every lane does,
# or the app is talking to a different WebKit depending on which interpreter
# happened to be installed. JavaScriptCore is versioned alongside WebKit2 and
# comes out of the same package, so it is asked for with the same number
# rather than probed separately.
WEBKIT_API = None
for candidate in ("4.1", "4.0"):
    try:
        gi.require_version("WebKit2", candidate)
        gi.require_version("JavaScriptCore", candidate)
        WEBKIT_API = candidate
        break
    except Exception:
        continue

if WEBKIT_API is None:
    unavailable("WebKit2 introspection typelibs not found")

try:
    gi.require_version("Gtk", "3.0")
    # Pinned alongside Gtk and not left to the loader. Importing it unpinned
    # writes a PyGIWarning to stderr on the way past, and this lane's stderr is
    # the app's.
    gi.require_version("Gdk", "3.0")
    # And Pango, for the same reason and with the same pin. It parses the
    # desktop's font descriptions; see read_fonts.
    gi.require_version("Pango", "1.0")
    from gi.repository import GLib, Gdk, Gio, Gtk, JavaScriptCore, Pango, WebKit2
except Exception as exc:
    unavailable("%s" % (exc,))

script_path = os.environ.get("NEUTRINO_SCRIPT_PATH", "")
if not script_path:
    unavailable("NEUTRINO_SCRIPT_PATH was not set")

try:
    handle = open(script_path, "rb")
    try:
        source = handle.read().decode("utf-8", "replace")
    finally:
        handle.close()
except Exception as exc:
    unavailable("could not read %s (%s)" % (script_path, exc))

if GLib.getenv("NEUTRINO_WEBKIT_SANDBOX") == "1":
    try:
        WebKit2.WebContext.get_default().set_sandbox_enabled(True)
    except Exception as exc:
        sys.stderr.write("neutrino: webkit sandbox unavailable: %s\n" % (exc,))
else:
    sys.stderr.write(
        "neutrino: webkit sandbox off: this system refused a user namespace\n")

# Without this the window's WM_CLASS is taken from argv[0], which on this lane
# is the descriptor the document was handed on -- a window belonging to an
# application called "9". The name is what a window manager groups, labels and
# hangs an icon off, so it is set before the first window exists.

ucm = WebKit2.UserContentManager()
view_holder = {}
committed = {"done": False}


def showing():
    view = view_holder.get("view")
    if view is None:
        return ""
    try:
        return view.get_uri() or ""
    except Exception:
        return ""


def on_message(_ucm, result):
    # The sender check. This handler hangs off the content manager rather than
    # off a document, so it hears from whatever the view is currently showing,
    # which is the one thing a message cannot lie about.
    where = showing()
    if not call("isTrustedView", js_string(where)).to_boolean():
        sys.stderr.write("neutrino: refused a message from %s\n" % (where,))
        return
    try:
        raw = result.get_js_value().to_string()
    except Exception:
        raw = ""
    route(raw)


def route(raw):
    message = call("parseMessage", js_string(raw))
    if message is None or not message.is_object():
        sys.stderr.write("neutrino: refused a malformed record\n")
        return
    action = message.object_get_property("action").to_string()
    if action == "resize":
        window.resize(
            message.object_get_property("width").to_int32(),
            message.object_get_property("height").to_int32(),
        )
    elif action == "move":
        window.move(
            message.object_get_property("x").to_int32(),
            message.object_get_property("y").to_int32(),
        )
    elif action == "resizeBy":
        # Against get_size, which is the pair to the resize above. The floor is
        # one pixel and it is here for the same reason it is in boot: the
        # splitter sees a delta and cannot know what it is a delta from.
        current_w, current_h = window.get_size()
        window.resize(
            max(1, current_w + message.object_get_property("width").to_int32()),
            max(1, current_h + message.object_get_property("height").to_int32()),
        )
    elif action == "moveBy":
        current_x, current_y = window.get_position()
        window.move(
            current_x + message.object_get_property("x").to_int32(),
            current_y + message.object_get_property("y").to_int32(),
        )
    elif action == "close":
        window.destroy()
    elif action == "openExternal":
        open_external(message.object_get_property("url").to_string())


def open_external(url):
    # Asked again here as well as in the splitter, because this is the end of
    # the line and it hands a string to the desktop's URI handler, which will
    # act on a file: url or a .desktop entry given one. It is also where the
    # navigation refusal below arrives, so the tier half of the question closes
    # that route as well as this one.
    if not call("mayOpenExternal", js_string(url)).to_boolean():
        return
    try:
        Gio.AppInfo.launch_default_for_uri(url, None)
    except Exception:
        # An argv and never a command line: a url holding a space would
        # otherwise become two arguments and one holding a quote something
        # else entirely.
        try:
            GLib.spawn_async(
                None, ["xdg-open", url], None, GLib.SpawnFlags.SEARCH_PATH, None)
        except Exception:
            pass


ucm.register_script_message_handler("neutrino")
ucm.connect("script-message-received::neutrino", on_message)


def inject(text, when):
    if not text:
        return
    try:
        ucm.add_script(WebKit2.UserScript.new(
            text, WebKit2.UserContentInjectedFrames.TOP_FRAME, when, None, None))
    except Exception as exc:
        sys.stderr.write("neutrino: could not inject: %s\n" % (exc,))


# The API first, at document start, then the page's own code once there is a
# document to run it against. Both go in through the engine rather than being
# spliced into the markup, which is what lets the document forbid script of
# its own.
view = WebKit2.WebView(user_content_manager=ucm)

# The JavaScriptCore context is built here, after the WebView and not before it,
# and that ordering is the whole reason this lane renders anything.
#
# Measured: a JSC.Context created before the first WebKit2.WebView leaves the
# view loading forever. The window comes up, the main loop runs, the view is
# mapped, is_loading() stays True and the progress sticks at 0.1 -- and no
# load-changed event is ever emitted, not even STARTED, because the web process
# is never spawned at all. Only WebKitNetworkProcess appears beside it. Every
# reading looked like a healthy app with an empty window.
#
# Constructing the WebView first is what settles it; a context made after that
# point, or after the load, or seconds later, all render normally. Bisected
# against a bare PyGObject WebView: the same script differs only in when the
# context is made, and that alone decides whether the page ever loads.
#
# So nothing above this line may touch JavaScriptCore, and the user scripts are
# added to the content manager below rather than before the view exists -- the
# manager applies them to loads that have not started yet, and the load is the
# last thing this file does.
ctx = JavaScriptCore.Context.new()


def raised():
    exc = ctx.get_exception()
    if exc is None:
        return None
    ctx.clear_exception()
    return exc.get_message()


def js_string(text):
    return JavaScriptCore.Value.new_string(ctx, text)


def js_number(value):
    return JavaScriptCore.Value.new_number(ctx, value)


def js_null():
    return JavaScriptCore.Value.new_null(ctx)


# The palette is the one thing this lane hands over as an object rather than as
# a string or a number, and it goes through JSON rather than through
# Value.new_object and a walk of set_property calls. Not for brevity: the walk
# is a second place where a key can be spelled differently from the way
# normalizeTheme reads it, and json.dumps is the only quoting rule involved.
def js_json(value):
    return JavaScriptCore.Value.new_from_json(ctx, json.dumps(value))


# The source arrives with a parameter named NeutrinoPy defined, which is how
# run() at the bottom of it knows not to go looking for a driver of its own.
# It is a parameter and not a global for the reason the QML document gives:
# nothing this file defines should land in the shim's scope.
ctx.evaluate(
    "var NT = (function (NeutrinoPy) {\n"
    + source
    + "\n; return NeutrinoWebview; })(true);\n"
    "var NTNOTES = [];\n"
    "NT.noteSink = function (m) { NTNOTES.push(String(m)); };\n",
    -1,
)
failed = raised()
if failed is not None:
    unavailable("could not evaluate the app source (%s)" % (failed,))

nt = ctx.get_value("NT")
notes = ctx.get_value("NTNOTES")
if nt is None or not nt.is_object():
    unavailable("the app source did not yield a NeutrinoWebview")


def drain():
    # note() has no channel of its own here: printerr is gjs's and console is
    # the page's, and neither exists in a bare JavaScriptCore context. Without
    # the sink installed above, every refusal the shared code reports -- an
    # openExternal an offline build declined, a view that did not say which
    # document it committed -- would happen silently on this lane and on no
    # other. So they are collected there and emptied here, after every call
    # that could have produced one.
    count = notes.object_get_property("length").to_int32()
    for index in range(count):
        sys.stderr.write(notes.object_get_property_at_index(index).to_string() + "\n")
    if count:
        notes.object_invoke_method("splice", [js_number(0), js_number(count)])


def call(name, *args):
    result = nt.object_invoke_method(name, list(args))
    failure = raised()
    drain()
    if failure is not None:
        raise RuntimeError("%s: %s" % (name, failure))
    return result


config = nt.object_get_property("config")
title = config.object_get_property("title").to_string()
width = config.object_get_property("width").to_int32()
height = config.object_get_property("height").to_int32()
# Through the shared predicate rather than by comparing the string here, which
# is this lane's whole rule: the launcher's own JavaScript decides, and Python
# asks it. A second spelling of `== "none"` on the one lane that does not have
# to have one is exactly the drift the other four are protected from.
decorated = not call("undecorated").to_boolean()


# The desktop's palette, and the one thing this lane does reimplement: the walk
# over a Gtk style context, because a Gtk widget cannot be handed to
# JavaScriptCore and the launcher's own reader takes one.
#
# Nothing that decides anything is written twice. The names come out of the
# launcher's gtkColorNames, in its order; each colour goes back through its
# toHex and its flattenColor; and the result is judged by its normalizeTheme.
# What is duplicated is the loop, and a loop cannot disagree about a colour.
#
# A Gtk.Box for the reason createGjsDriver's readTheme gives: these are
# theme-level names, measured identical on Box, Label and Window, and building a
# toplevel to read a colour would be a second window in a launcher whose whole
# job is the first one.
def read_theme():
    try:
        style = Gtk.Box().get_style_context()
    except Exception as exc:
        sys.stderr.write("neutrino: could not read the desktop theme: %s\n" % (exc,))
        return None
    names = nt.object_get_property("gtkColorNames").to_string().split(",")
    keys = nt.object_get_property("themeKeys").to_string().split(",")
    if len(names) != len(keys):
        sys.stderr.write("neutrino: the palette and its GTK names are different lengths\n")
        return None
    hexes = []
    alphas = []
    for name in names:
        found = style.lookup_color(name)
        if not found[0]:
            sys.stderr.write("neutrino: this theme defines no %s\n" % (name,))
            return None
        rgba = found[1]
        hexes.append(call("toHex", js_json({
            "red": rgba.red, "green": rgba.green, "blue": rgba.blue,
        })).to_string())
        alphas.append(rgba.alpha)
    # Flattened against the background, which is why it is read first. A
    # translucent border over white is a light border on a dark desktop.
    raw = {"source": "gtk"}
    for index in range(len(keys)):
        raw[keys[index]] = call(
            "flattenColor", js_string(hexes[index]),
            js_number(alphas[index]), js_string(hexes[0]),
        ).to_string()
    return raw


# Held as the JavaScript value the launcher returned rather than as anything of
# this lane's own, so that themesDiffer is comparing what it built to what it
# built. `theme` on the launcher object is set alongside it for the same reason
# every other value here is read back out of that object: one truth.
theme_state = {"value": js_null()}


def take_theme():
    raw = read_theme()
    if raw is None:
        return False
    taken = call("normalizeTheme", js_json(raw))
    if taken.is_null() or taken.is_undefined():
        return False
    if not call("themesDiffer", theme_state["value"], taken).to_boolean():
        return False
    theme_state["value"] = taken
    nt.object_set_property("theme", taken)
    return True


if not take_theme():
    sys.stderr.write("neutrino: could not read the desktop palette; using %s\n" % (
        call("resolveBackground", theme_state["value"]).to_string(),))


# The desktop's fonts, and the second thing this lane reimplements -- but less
# of it than the palette.
#
# A font is a string, and strings cross into JavaScriptCore fine, so nothing
# here has to hold a GTK object the way read_theme holds a style context. What
# cannot cross is Pango.FontDescription, which lives in this interpreter. So the
# split is by what needs a runtime and not by lane: the GSettings walk and the
# Pango parse are written twice, once here and once in createGjsDriver, and
# every decision -- which schema wins, the titlebar rule, the alias map, the
# fallbacks -- is in else/font-gtk.js and is called from both. Two loops cannot
# disagree about a font; two copies of a rule can.
#
# The schema lookups go through Gio.SettingsSchemaSource first, and that is not
# defensiveness: Gio.Settings on a schema this machine does not carry calls
# g_error(), which aborts the process outright. No exception, nothing to catch,
# no line after it.
font_settings = []


def open_settings(schema_id):
    try:
        source = Gio.SettingsSchemaSource.get_default()
        if source is None or source.lookup(schema_id, True) is None:
            return None
        settings = Gio.Settings.new(schema_id)
    except Exception as exc:
        sys.stderr.write("neutrino: could not open %s: %s\n" % (schema_id, exc))
        return None
    # Held for the life of the process. A Gio.Settings that is collected stops
    # emitting, so a watcher without a reference works until the collector
    # notices and then silently does not.
    font_settings.append(settings)
    return settings


# A schema being present does not mean the key is: Cinnamon's interface schema
# was measured carrying font-name and neither document-font-name nor
# monospace-font-name.
def setting_string(settings, key):
    if settings is None or key not in settings.list_keys():
        return ""
    return settings.get_string(key) or ""


# get_boolean and not get_string. Asking a boolean key for a string prints a
# GLib CRITICAL and hands back None, which the probe found the loud way.
def setting_bool(settings, key):
    if settings is None or key not in settings.list_keys():
        return False
    return bool(settings.get_boolean(key))


def gather_font_strings():
    gathered = {"gtkFontName": "", "names": {}, "interface": {},
                "titlebar": "", "titlebarSystem": False}
    settings = Gtk.Settings.get_default()
    if settings is not None:
        gathered["gtkFontName"] = settings.get_property("gtk-font-name") or ""
    ids = nt.object_get_property("gtkFontSchemas").to_string().split(",")
    opened = {}
    for schema_id in ids:
        opened[schema_id] = open_settings(schema_id)
        name = setting_string(opened[schema_id], "font-name")
        if name != "":
            gathered["names"][schema_id] = name
    chose = call("gtkFontSchemaChoice",
                 js_string(gathered["gtkFontName"]),
                 js_json(gathered["names"])).to_string()
    if chose != "" and opened.get(chose) is not None:
        for key in nt.object_get_property("gtkFontKeys").to_string().split(","):
            gathered["interface"][key] = setting_string(opened[chose], key)
    for schema_id in nt.object_get_property("gtkFontWmSchemas").to_string().split(","):
        wm = open_settings(schema_id)
        if wm is None:
            continue
        titlebar = setting_string(wm, "titlebar-font")
        if titlebar == "":
            continue
        gathered["titlebar"] = titlebar
        gathered["titlebarSystem"] = setting_bool(wm, "titlebar-uses-system-font")
        break
    return gathered


# Pango, on the strings gtkChooseFontStrings picked. An absolute size is device
# units rather than points and is converted here, so what leaves this lane is
# points throughout and the raw object carries one unit rather than one a role.
def parse_font_strings(chosen):
    out = {}
    for role in nt.object_get_property("fontRoles").to_string().split(","):
        text = chosen.get(role, "")
        if not text:
            continue
        desc = Pango.FontDescription.from_string(text)
        size = desc.get_size() / Pango.SCALE
        if desc.get_size_is_absolute():
            size = size * 72.0 / 96.0
        fields = call("gtkRoleFields", js_string(role), js_json({
            "family": desc.get_family() or "",
            "size": size,
            "weight": int(desc.get_weight()),
        }))
        out[role] = json.loads(fields.to_json(0))
    return out


def read_fonts():
    try:
        gathered = gather_font_strings()
        chosen = json.loads(
            call("gtkChooseFontStrings", js_json(gathered)).to_json(0))
        return json.loads(
            call("gtkFontsFromParsed", js_json(parse_font_strings(chosen))).to_json(0))
    except Exception as exc:
        sys.stderr.write("neutrino: could not read the desktop fonts: %s\n" % (exc,))
        return None


# Held the same way theme_state is, and for the same reason: fontsDiffer has to
# be comparing what the launcher built to what the launcher built.
fonts_state = {"value": js_null()}


def take_fonts():
    raw = read_fonts()
    if raw is None:
        return False
    taken = call("normalizeFonts", js_json(raw))
    if taken.is_null() or taken.is_undefined():
        return False
    if not call("fontsDiffer", fonts_state["value"], taken).to_boolean():
        return False
    fonts_state["value"] = taken
    nt.object_set_property("fonts", taken)
    return True


if not take_fonts():
    sys.stderr.write("neutrino: could not read the desktop fonts; "
                     "the page falls back to the engine's own\n")


# The scheme, and this lane asks the launcher whether to raise the flag rather
# than looking at the palette itself -- gtkPreferDark says why it is raised and
# never lowered, and a second copy of that reasoning here is a second thing that
# can drift from the gjs driver's.
#
# Called before the window for the reason boot calls it there: the media query
# is a value the first paint is already styled by.
def force_scheme():
    if not call("gtkPreferDark", theme_state["value"]).to_boolean():
        return
    settings = Gtk.Settings.get_default()
    if settings is None:
        return
    try:
        if settings.get_property("gtk-application-prefer-dark-theme"):
            return
        settings.set_property("gtk-application-prefer-dark-theme", True)
    except Exception as exc:
        sys.stderr.write("neutrino: could not force the colour scheme: %s\n" % (exc,))


force_scheme()


# The two surfaces GTK puts up before the document, and the colour comes out of
# the launcher's own resolveBackground rather than being decided again here.
# This lane reimplements nothing on purpose, and a second reading of the same
# value is a second thing that can disagree with the other four.
#
# Both calls are allowed to fail. A background that will not paint is a window
# in the theme colour, which is where this started -- worth a line on stderr,
# not worth refusing to launch over.
def paint(widget_window, web_view, background):
    rgb = call("parseColor", js_string(background))
    if rgb.is_null() or rgb.is_undefined():
        return
    red = rgb.object_get_property("red").to_double()
    green = rgb.object_get_property("green").to_double()
    blue = rgb.object_get_property("blue").to_double()
    try:
        rgba = Gdk.RGBA()
        rgba.red, rgba.green, rgba.blue, rgba.alpha = red, green, blue, 1.0
        web_view.set_background_color(rgba)
    except Exception as exc:
        sys.stderr.write("neutrino: could not paint the view: %s\n" % (exc,))
    try:
        # On the widget and not on the screen: the screen-wide call reaches
        # every window in the process, and there is one here only by accident
        # of there being one window.
        provider = Gtk.CssProvider()
        provider.load_from_data(
            ("window, .background { background-color: rgb(%d,%d,%d); }" % (
                round(red * 255), round(green * 255), round(blue * 255))).encode("utf-8"))
        widget_window.get_style_context().add_provider(
            provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    except Exception as exc:
        sys.stderr.write("neutrino: could not paint the window: %s\n" % (exc,))

html = call(
    "dressedDocument",
    call(
        "titledDocument",
        call("extractHtmlDocument", js_string(source)),
        js_string(title),
    ),
    theme_state["value"],
    fonts_state["value"],
).to_string()
page_script = call("extractPageScript", js_string(source)).to_string()
preload = call(
    "buildPreloadScript",
    js_string("window.webkit.messageHandlers.neutrino.postMessage"),
    js_string("scriptmessage"),
    # In the preload rather than pushed after it, so the page has the palette
    # at document start and never paints once in the wrong colours first.
    call("themeLiteral", theme_state["value"]),
    call("fontsLiteral", fonts_state["value"]),
).to_string()

# Asked for before a WebView exists, and taken back if it does not arrive.
# Both halves matter and the comment in createGjsDriver's init records why:
# WebKitGTK aborts outright if sandboxing is changed once a web process has
# been spawned, and a sandbox that cannot start gives a window with nothing in
# it. The value is a measurement the launcher took with bwrap itself, never a
# switch read from the environment.
inject(preload, WebKit2.UserScriptInjectionTime.START)
inject(page_script, WebKit2.UserScriptInjectionTime.END)

GLib.set_prgname("neutrino")

window = Gtk.Window(
    title=title,
    default_width=width,
    default_height=height,
    decorated=decorated,
)
window.set_position(Gtk.WindowPosition.CENTER)
window.connect("destroy", lambda _w: Gtk.main_quit())
paint(window, view, call("resolveBackground", theme_state["value"]).to_string())
view_holder["view"] = view


# The watcher, and the same signal the gjs lane uses: `style-updated` is what
# GTK emits when the style behind a widget changes for any reason, rather than
# one of the several settings that can cause it.
#
# take_theme's diff is what makes this safe to connect at all. Painting the
# window adds a CssProvider to it, which emits this signal -- so without the
# diff the first theme change would be the last thing this process did.
def on_style_updated(_widget):
    if not take_theme():
        return
    # Before the paint, because raising the flag is a thing GTK may answer by
    # changing the palette, and a paint that ran first would be painting the
    # one it was about to replace.
    force_scheme()
    if call("followsTheme").to_boolean():
        paint(window, view, call("resolveBackground", theme_state["value"]).to_string())
    # Before the commit there is no document of ours to evaluate into. Nothing
    # is lost: the page starts from the preload's snapshot either way.
    if not committed["done"]:
        return
    js = call("buildThemeScript", theme_state["value"])
    if js.is_null() or js.is_undefined():
        return
    try:
        # run_javascript and not evaluate_javascript, because this lane resolves
        # WebKit2 to 4.1 or 4.0 and only the first carries the newer spelling.
        view.run_javascript(js.to_string(), None, None, None)
    except Exception as exc:
        sys.stderr.write("neutrino: could not deliver the theme: %s\n" % (exc,))


# The fonts, delivered the way on_style_updated delivers a palette and with the
# repaint left out -- a font change has no native surface, which is what makes
# applyFonts shorter than applyTheme on every other lane.
def deliver_fonts():
    if not take_fonts():
        return
    if not committed["done"]:
        return
    js = call("buildFontScript", fonts_state["value"])
    if js.is_null() or js.is_undefined():
        return
    try:
        view.run_javascript(js.to_string(), None, None, None)
    except Exception as exc:
        sys.stderr.write("neutrino: could not deliver the fonts: %s\n" % (exc,))


def on_style_updated_all(widget):
    on_style_updated(widget)
    # `style-updated` fires for a font change too, twice, and the first time
    # GtkSettings still holds the old value -- measured, six firings for one
    # `font-name` write. take_fonts' diff drops the stale first as a duplicate
    # and the second carries the new one.
    deliver_fonts()


window.connect("style-updated", on_style_updated_all)


# And the setting behind it, for the reason createGjsDriver's runEventLoop
# gives at length: `style-updated` is about this widget's own computed style
# and not about the theme, so a change that leaves the window drawing itself
# identically never reaches it. Measured on Mint 22 / Cinnamon / GTK 3.24 over
# five theme changes, this fired 5 times and `style-updated` fired 2 -- the
# three it missed being the desktop's accent picker, which moves
# theme_selected_bg_color and leaves the canvas where it was.
#
# The handler is the same one, because the work either signal asks for is
# identical and take_theme drops whichever of the two arrives second.
def on_theme_name(_settings, _pspec):
    on_style_updated(None)


# The font's own cause signal, which of the six firings measured for one change
# is the only one carrying the new value at the moment it fires.
def on_font_name(_settings, _pspec):
    deliver_fonts()


try:
    gtk_settings = Gtk.Settings.get_default()
    if gtk_settings is not None:
        gtk_settings.connect("notify::gtk-theme-name", on_theme_name)
        gtk_settings.connect("notify::gtk-font-name", on_font_name)
except Exception as exc:
    sys.stderr.write("neutrino: no settings watcher on this lane: %s\n" % (exc,))


# And the three roles GtkSettings has no key for.
#
# Redundant on a desktop with a settings daemon and not redundant everywhere,
# which is why they stay; createGjsDriver's twin of this carries the measurement
# that settles it. In short: the daemon that writes a GSettings key also touches
# something a window's style notices, so `style-updated` carries the change
# there -- and on a machine with no daemon, which is this suite's own runner,
# nothing else can. Neither signal is a superset of the other.
#
# font_settings holds the objects read_fonts already opened -- and holding them
# is what keeps them emitting at all.
def on_font_key(_settings, _key):
    deliver_fonts()


try:
    watched = (nt.object_get_property("gtkFontKeys").to_string().split(",") +
               nt.object_get_property("gtkFontWmKeys").to_string().split(","))
    for settings in font_settings:
        keys = settings.list_keys()
        for key in watched:
            # font-name is skipped: notify::gtk-font-name above is the same
            # change seen from the side that is not stale.
            if key == "font-name" or key not in keys:
                continue
            settings.connect("changed::" + key, on_font_key)
except Exception as exc:
    sys.stderr.write("neutrino: no font-settings watcher on this lane: %s\n" % (exc,))


def on_load_changed(_view, event):
    # COMMITTED and not FINISHED, and the difference is a hole: the author's
    # script runs at document end, which is after the commit and before the
    # load finishes, so a navigation started from there would be decided while
    # this was still false. A stylesheet on a socket that never answers holds
    # the load open for as long as the page likes.
    if event == WebKit2.LoadEvent.COMMITTED:
        committed["done"] = True
        try:
            call("rememberTrustedView", js_string(view.get_uri() or ""))
        except Exception:
            pass


view.connect("load-changed", on_load_changed)

settings = view.get_settings()
try:
    settings.set_enable_developer_extras(False)
    settings.set_allow_file_access_from_file_urls(False)
    settings.set_allow_universal_access_from_file_urls(False)
    settings.set_javascript_can_access_clipboard(False)
    settings.set_enable_write_console_messages_to_stdout(False)
except Exception:
    pass


def on_decide_policy(_view, decision, kind):
    # The document is loaded once, from this file, and never navigates again.
    # Without this a link or a location assignment could replace it with a
    # remote origin, and that origin would then be holding the channel to the
    # native window -- the preload is registered on the content manager, so it
    # is reinjected into whatever document arrives next.
    types = WebKit2.PolicyDecisionType
    if kind != types.NAVIGATION_ACTION and kind != types.NEW_WINDOW_ACTION:
        return False
    try:
        uri = decision.get_navigation_action().get_request().get_uri() or ""
    except Exception:
        uri = ""
    # Until the first document is committed the only navigation in flight is
    # the one this file started, and its decision is taken before any load
    # event fires. Keying on that as well as on the url means an engine that
    # spells the initial load differently cannot lock the app out of its own
    # document.
    if not committed["done"] or call("isOwnDocument", js_string(uri)).to_boolean():
        return False
    decision.ignore()
    sys.stderr.write("neutrino: refused navigation to %s\n" % (uri,))
    open_external(uri)
    return True


view.connect("decide-policy", on_decide_policy)


# This lane's half of the title hook, and the same signal the gjs lane connects.
# `notify::title` is GObject's own, so it fires for a `<title>` the parser met
# and for an assignment the page made alike, and the value read back is the
# engine's rather than anything the page handed over.
#
# showing() is the reader the message handler already uses, so the sender check
# here and the sender check there cannot drift apart.
def on_title(view_object, _pspec):
    name = call("acceptDocumentTitle", js_string(showing()),
                js_string(view_object.get_title() or ""))
    if not name.is_null():
        window.set_title(name.to_string())


view.connect("notify::title", on_title)

view.load_html(html, None)
window.add(view)
window.show_all()
Gtk.main()
