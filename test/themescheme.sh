#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# themescheme.sh - one launch on a desktop built to make the media query lie.
#
# Usage: themescheme.sh <artifact> [screenshot-dir]
#
# `prefers-color-scheme` on WebKitGTK is a *name*, not a palette. The engine
# answers dark when the toolkit's prefer-dark flag is raised or when the theme's
# name carries the dark variant, and neither of those is what is on screen. So a
# theme whose palette is dark and whose name is not gets a page that is handed
# `neutrino.theme.scheme === "dark"`, `--neutrino-Canvas: #2e2e33`, and a media
# query that says light.
#
# That is not a contrived desktop. Mint ships `Mint-Y-Dark-Grey`,
# `Mint-L-Dark-Blue` and some twenty more in the same families: the same dark
# grey as `Mint-Y-Dark`, named for the accent instead of the variant, and every
# one of them measured light by the engine and dark by this launcher. It is
# reached by picking a theme from the distribution's own list.
#
# What runs here is a theme this file writes, and the reason is not that no
# installed one would do. It is that which themes are installed is a property of
# the runner: this suite has to fail for one reason on every lane it runs on, and
# `Mint-Y-Dark-Grey` exists on a Mint desk and on no CI image. A theme whose
# palette is a constant in this file is also the honest instrument -- the colour
# asserted below is the colour written above, and there is no third party in
# between to be wrong about it.
#
# Three assertions and the order matters, because the first two are what stop a
# green from being an accident:
#
#   the theme loaded    the palette the launcher read is the palette written
#                       here. Without it a run whose GTK_THEME never took would
#                       read the runner's own light desktop, agree with a light
#                       media query, and pass.
#   the palette is dark `nscheme=dark`, which is the launcher's luminance rule
#                       applied to the colour above. A derived number and its
#                       input are two readings and both are here.
#   the query agrees    `mq=dark`. This is the one the round exists for, and it
#                       is the one that fails with the force taken out.
#
# The last is verify-std.sh's own assertion, so this file does not repeat it: it
# runs the verifier, carries its status, and adds the two preconditions the
# verifier cannot know about because they are about the desktop it was pointed
# at rather than about what the page said.

set -uo pipefail

ART="${1:-test/neutrinostdtheme.cmd}"
SHOTS="${2:-$HOME/screenshots}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="${NT_SCHEME_LOGDIR:-$HOME}"

# Not `themescheme.log`, and the reason is a line of this suite's own record.
# The step that runs this file sends its stdout to `~/themescheme.log`, and the
# first version of this file gave the verifier the same path: two writers on one
# file, opened at two offsets. `cat` refused it -- "input file is output file" --
# and the harness's own next line landed inside the verifier's, so the annotation
# read `turns=153cat: ...`. Every value in that record was right and the record
# was not readable. A log a caller redirects into is not a name a callee may
# reuse.
VERIFY_LOG="$LOGDIR/themescheme-verify.log"

# The six words. This file had no `pass`: its two controls each had a counted
# `fail` branch and a `note` branch, so the run where both held said nothing at
# all -- and they are the two readings that stop a green from being an accident.
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"
# And the question themeflip.sh and decoflip.sh ask ahead of their own launches,
# in the words all three now share.
. "$(cd "$(dirname "$0")" && pwd)/lib/title.sh"

note() { nt_report "$*"; }

skip_controls() {
    nt_skip themescheme.control.theme-loaded "$1"
    nt_skip themescheme.control.dark "$1"
}

# The name, and it is the whole apparatus. No `-dark` suffix and no `:dark`
# variant, because a name carrying either is a name the engine reads instead of
# the palette -- which is the mechanism under test and not a thing to hand it.
THEME_NAME="NeutrinoDarkNamedPlain"

# The palette. Dark enough that no threshold is being argued about: #24242a has
# a relative luminance around 0.017 against the launcher's crossing near 0.179,
# so a rule that disagreed here would be disagreeing about something other than
# the number.
BG="#24242a"
FG="#eeeeee"
BASE="#1c1c21"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/themes/$THEME_NAME/gtk-3.0"
cat > "$WORK/themes/$THEME_NAME/gtk-3.0/gtk.css" <<CSS
@define-color theme_bg_color $BG;
@define-color theme_fg_color $FG;
@define-color theme_base_color $BASE;
@define-color theme_text_color $FG;
@define-color theme_selected_bg_color #3584e4;
@define-color theme_selected_fg_color #ffffff;
@define-color borders #131317;
window, .background { background-color: @theme_bg_color; color: @theme_fg_color; }
CSS

echo "themescheme.sh: artifact=$ART theme=$THEME_NAME bg=$BG"

# A window carrying the prefix, from anywhere. Before the launch and not after
# it: both this suite and every other STD-THEME- step in the lane answer to the
# same name, and a window that outlived an earlier step is one the verifier
# would attach to and report about. themeflip.sh lost a round to exactly this.
if nt_title_live 'STD-THEME-'; then
    nt_fail themescheme.clean-start "a STD-THEME- window was already up before this launch; it would be read instead"
    nt_skip themescheme.reported "an older window would have been read, so this launch was not made"
    skip_controls "an older window would have been read, so this launch was not made"
    nt_finish
fi
nt_pass themescheme.clean-start "no STD-THEME- window was up before this launch"

# Prepended, never replacing: the runner's own data dirs carry the icon themes
# and the schemas GTK needs to come up at all, and a launcher that cannot open a
# window is not a reading about colour schemes.
export XDG_DATA_DIRS="$WORK:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export GTK_THEME="$THEME_NAME"

bash "$ART" > "$LOGDIR/themescheme-app.log" 2>&1 &
APP=$!
VERIFY=0
# Named for the desktop it built, not for the probe it ran. This launch used to
# overwrite the plain theme step's picture with one taken under a theme that
# exists only inside this file, and nothing in the artifact said so.
NT_SHOT_NAME="theme-misnamed-dark" \
    bash "$ROOT/test/verify-std.sh" theme "$SHOTS" > "$VERIFY_LOG" 2>&1 || VERIFY=$?
pkill -P "$APP" 2>/dev/null || true
kill "$APP" 2>/dev/null || true

cat "$VERIFY_LOG"

PAL="$(sed -n 's/^report: self palette //p' "$VERIFY_LOG" | head -1)"
val() { nt_field "$1" "$PAL"; }

if [ -z "$PAL" ]; then
    nt_fail themescheme.reported "the app never reported a palette; there is no reading here to judge"
    skip_controls "no palette was reported, so there was nothing to hold against what this file wrote"
    nt_finish
fi
nt_pass themescheme.reported "the app reported a palette"

GOT_BG="$(val 'n:background')"
WANT_BG="${BG#\#}"
if [ "$GOT_BG" = "$WANT_BG" ]; then
    nt_pass themescheme.control.theme-loaded "control theme loaded background=$GOT_BG verdict=TOOK"
else
    nt_fail themescheme.control.theme-loaded "control theme did not load: the launcher read background=$GOT_BG where this file wrote $WANT_BG -- GTK_THEME never reached the app, so the desktop below is the runner's and not this one's"
fi

GOT_SCHEME="$(val nscheme)"
if [ "$GOT_SCHEME" = dark ]; then
    nt_pass themescheme.control.dark "control palette dark nscheme=dark verdict=DARK"
else
    nt_fail themescheme.control.dark "control palette: the launcher called $WANT_BG '$GOT_SCHEME'; the luminance rule and this file's idea of a dark colour disagree, and nothing below is about the media query"
fi

note "themescheme mq=$(val mq) neutrino=$GOT_SCHEME verifier=$VERIFY"

# The verifier's own count, carried. nt_finish exits $NT_FAILURES and this file
# has a second half to add to it -- the media-query assertion is verify-std.sh's
# and is filed there as std.theme.*, so what comes back here is a status and not
# a case. harness.sh names this shape: a caller with arithmetic of its own reads
# NT_FAILURES and calls nothing.
nt_report "totals themescheme passes=$NT_PASSES failures=$((NT_FAILURES + VERIFY)) skips=$NT_SKIPS"
exit "$((NT_FAILURES + VERIFY))"
