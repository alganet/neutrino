#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# nobrowser.sh - stand in front of the desktop's URI handler, for a whole lane.
#
# `mayOpenExternal` ends at `xdg-open` on the X lanes -- the launcher spawns it
# by name with SEARCH_PATH -- so any step that opens an external url starts
# whatever browser the runner has. On the `gjs` image that is Google Chrome,
# which comes up showing "Google Chrome and ChromeOS Additional Terms of
# Service" and then sits on the display for the rest of the job. It was in seven
# of eight of that lane's captures in the first run that looked, and it had been
# there for every run before that with nothing to notice it.
#
# verify-offline.sh already installs a shim exactly like this one, and its
# readings were never the problem: it puts the shim on PATH inside its own step
# and the browser was started by a step somewhere else. So the fix is not a
# better shim, it is a shim with the lane's lifetime instead of a step's.
#
# This installs one before anything runs and exports it through $GITHUB_PATH, so
# every later step inherits it. verify-offline.sh's own shim still wins inside
# its step, because it prepends its own directory to PATH and this one is
# further down.
#
# Nothing is lost. The X lanes never wanted a real browser: verify-offline.sh
# sets BROWSERS="" and EXPECT_NAVOUT=MISS on this platform precisely because the
# shim is what they measure through, and the claim that a url handed to the
# desktop actually gets retrieved is measured on macOS, where NSWorkspace has no
# seam a PATH entry can stand in front of.
#
# Usage: nobrowser.sh   (no arguments; call once, early, on an X lane)

set -uo pipefail

SHIM="$HOME/nobrowser"
LOG="$HOME/nobrowser.log"

mkdir -p "$SHIM" "$HOME/.local/share/applications" "$HOME/.config"
: > "$LOG"

# Records and does not fetch, for the reason verify-offline.sh gives about its
# own: a handler that goes and gets the url puts a second author in the target
# server's log and the two routes stop being separable.
cat > "$SHIM/xdg-open" <<EOS
#!/bin/sh
echo "handler \$*" >> "$LOG"
EOS
chmod +x "$SHIM/xdg-open"

# Both routes, because the two toolkits ask different things first: gjs asks Gio
# and Qt asks QDesktopServices, and each consults the desktop's registered
# handler before falling back to a PATH lookup.
cat > "$HOME/.local/share/applications/neutrino-nobrowser.desktop" <<EOS
[Desktop Entry]
Type=Application
Name=neutrino CI url sink
Exec=$SHIM/xdg-open %u
Terminal=false
NoDisplay=true
MimeType=x-scheme-handler/http;x-scheme-handler/https;
EOS
cat > "$HOME/.config/mimeapps.list" <<EOS
[Default Applications]
x-scheme-handler/http=neutrino-nobrowser.desktop
x-scheme-handler/https=neutrino-nobrowser.desktop
EOS
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

# Every later step in the job, which is the whole point of doing this here
# rather than inside one.
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$SHIM" >> "$GITHUB_PATH"
    echo "  nobrowser: $SHIM is on PATH for every step after this one"
else
    echo "  nobrowser: no \$GITHUB_PATH; export PATH=\"$SHIM:\$PATH\" yourself"
fi
echo "  nobrowser: urls handed to the desktop will be recorded in $LOG"
