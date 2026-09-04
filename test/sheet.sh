#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# sheet.sh - one lane's pictures and logs, as a single file that opens in a browser.
#
# Usage: sheet.sh <lane> <out.html> [<label>=]<dir-or-file> ...
#
# What this replaces is a directory of PNGs in a zip. A reader who wanted to
# know whether the chromeless window looked right had to download the zip,
# extract it, find the file, open it, and then remember what the decorated one
# looked like in order to compare -- which is four steps and a memory test
# standing between a run and the one thing a screenshot is for.
#
# So: every picture in one page, captioned with what it is a picture of, laid
# out so the pairs this suite exists to compare sit beside each other, with the
# verifier logs folded in underneath. One file, no assets, no network. Pictures
# are inlined as `data:` URIs, which a browser resolves and GitHub's markdown
# sanitiser strips -- that is why this is an artifact and not a job summary, and
# it was measured rather than assumed: every `data:` URI put through GitHub's
# own `POST /markdown` comes back with the `src` attribute deleted.
#
# Bash on every lane, including Windows, where the workflow already runs bash
# steps. One implementation rather than one per platform: the last thing a
# reporting tool should be is a thing that reports differently depending on
# where it ran.

set -uo pipefail

LANE="${1:?usage: sheet.sh <lane> <out.html> [<label>=]<dir>...}"
OUT="${2:?usage: sheet.sh <lane> <out.html> [<label>=]<dir>...}"
shift 2

# GNU base64 wraps at 76 columns unless told -w0; BSD base64 has no -w and does
# not wrap. Neither spelling works on both, so try the flag and fall back.
#
# The fallback redirects rather than passing the name, and that is the whole
# bug this function shipped with for a round. BSD base64's usage is
# `base64 [-hDd] [-b num] [-i in_file] [-o out_file]` -- there is no operand
# form, so `base64 "$1"` ignores the argument and reads standard input. Every
# `src` in the macOS sheet came out empty while the Linux one was perfect, and
# the page was well-formed and correctly captioned throughout: fourteen figures,
# fourteen empty pictures. Worse, stdin at that point is the file the caller is
# looping over, so the fallback was reading the list of shots it was supposed to
# be encoding.
b64() { base64 -w0 "$1" 2>/dev/null || base64 < "$1" | tr -d '\n'; }

# What each picture is a picture of.
#
# The filenames are meaningful now -- that was the round before this one -- but
# a filename is a label and not a sentence, and the reader this page is for is
# checking a feature rather than auditing a suite. `frame-chromeless` says which
# file it is; "built with --decorations none: no title bar, no border" says what
# should be in the frame, which is the thing being verified by eye.
subject() {
    case "$1" in
        00-initial)   echo "The window as it first appears" ;;
        01-step0)     echo "Walk: the app has started and reported in" ;;
        02-step1)     echo "Walk: document.title assigned -- the native title should have followed" ;;
        03-step2)     echo "Walk: after resizeTo(500, 400)" ;;
        04-step3)     echo "Walk: after moveTo(0, 0)" ;;
        05-theme)     echo "The desktop palette, as the app read it" ;;
        # Both spellings, because `05-done` is what windows-launch called this
        # for as long as it was the only lane with two pictures instead of
        # seven. It writes `06-done` like everywhere else now; the old name
        # stays so an artifact from before that round still opens captioned.
        05-done|06-done) echo "Walk: finished" ;;
        frame-decorated)  echo "Default frame -- title bar and border drawn by the window manager" ;;
        frame-chromeless) echo "Built with --decorations none -- no title bar, no border" ;;
        theme-light)      echo "Desktop flipped light; the page should follow" ;;
        theme-dark)       echo "Desktop flipped dark; the page should follow" ;;
        theme-misnamed-dark) echo "A dark palette under a light-sounding theme name -- the case prefers-color-scheme gets wrong" ;;
        std-theme)    echo "The palette, on the desktop this runner came with" ;;
        std-doc)      echo "document.title, reaching the native window title" ;;
        std-win)      echo "The standard window verbs -- resize, move, fullscreen, close" ;;
        std-geom)     echo "Window geometry" ;;
        # netinstall's own pictures, named for what drew the window. The
        # download behind them was stalled on purpose so the window was due, and
        # NEUTRINO_SPLASH_HOLD_MS kept it up while the shutters fired.
        #
        # The burst frames are matched first, because the portrait's pattern
        # would otherwise swallow them and caption six frames of an animation as
        # six portraits. They are not rendered as figures of their own -- see
        # the animation section below -- and this is here for the case where one
        # arrives without the others.
        splash-*-anim-*) echo "One frame of netinstall's splash, drawn with $(printf '%s' "${1#splash-}" | sed 's/-anim-.*//')" ;;
        splash-*)     echo "netinstall's splash window, drawn with ${1#splash-} over a download the host stalled; held open for the shutter by NEUTRINO_SPLASH_HOLD_MS" ;;
        *)            echo "" ;;
    esac
}

# Quotes as well as angle brackets, because this escapes attribute values and
# not only text. A shot called `quote"and<tag>.png` came through the stress
# fixture as alt="quote"and&lt;tag&gt;": the attribute ended at the second quote
# and the rest of the name became stray attributes. One function escapes both
# contexts here, so it has to be safe in the stricter of the two.
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

# Whether a file is really a PNG, by its signature and not by its name.
#
# The stress fixture put a zero-byte `empty.png` and a `corrupt.png` holding
# plain text through this and both came out as figures, one of them as
# `<img src="data:image/png;base64,">` -- a broken image with a caption under
# it, shipped in silence. On a page whose whole purpose is to be looked at, a
# picture that cannot render is worse than an absent one: it reads as a defect
# in the app rather than in the file.
is_png() {
    [ -s "$1" ] || return 1
    [ "$(head -c 8 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')" = "89504e470d0a1a0a" ]
}

# Collect the pictures and the logs separately: they are two kinds of thing and
# the page treats them differently. A directory contributes everything under it,
# so a lane can hand over `~/screenshots` and `~/netinstall-screenshots` and
# have the grouping come out of the paths rather than out of the workflow.
# Each source may carry a label -- `Frames=~/screenshots` -- and the label is
# what the reader sees as a heading. Derived from the path when it is left off,
# but a lane that knows why it is handing over two directories should say so:
# "netinstall" and "the suites" is a distinction a reader can use, and
# `/home/runner/netinstall-screenshots` is not.
SHOTS="$(mktemp)"; LOGS="$(mktemp)"
trap 'rm -f "$SHOTS" "$LOGS"' EXIT
for arg in "$@"; do
    case "$arg" in
        *=*) label="${arg%%=*}"; src="${arg#*=}" ;;
        *)   src="$arg"; label="$(basename "$src")" ;;
    esac
    [ -e "$src" ] || continue
    if [ -d "$src" ]; then
        find "$src" -type f -name '*.png' 2>/dev/null | sort |
            while IFS= read -r f; do printf '%s\t%s\n' "$label" "$f"; done >> "$SHOTS"
        find "$src" -type f -name '*.log' 2>/dev/null | sort >> "$LOGS"
    else
        case "$src" in
            *.png) printf '%s\t%s\n' "$label" "$src" >> "$SHOTS" ;;
            *.log) echo "$src" >> "$LOGS" ;;
        esac
    fi
done

# The burst frames come out of the grid and into a section of their own.
#
# They are six photographs of one thing, and six figures of them side by side is
# both the heaviest part of the page and the least informative: what a reader
# wants from a burst is the motion, which is the one thing a still grid cannot
# show. Below they become a single figure that cycles, and the grid keeps the
# portrait.
#
# Matched on the name and not on where the file came from, because the lane
# hands over a directory and not a list. `-anim-NN.png` is what
# nt_screenshot_burst writes and nothing else in this tree writes.
ANIMS="$(mktemp)"; STILLS="$(mktemp)"
trap 'rm -f "$SHOTS" "$LOGS" "$ANIMS" "$STILLS"' EXIT
grep -aE -- '-anim-[0-9]+\.png$' "$SHOTS" > "$ANIMS" 2>/dev/null || true
grep -avE -- '-anim-[0-9]+\.png$' "$SHOTS" > "$STILLS" 2>/dev/null || true

NSHOTS="$(wc -l < "$SHOTS" | tr -d ' ')"
NANIM="$(wc -l < "$ANIMS" | tr -d ' ')"
NLOGS="$(wc -l < "$LOGS" | tr -d ' ')"

# ------------------------------------------------------------------- the digest
#
# What the lane asserted, before what it looks like.
#
# The suites speak in `PASS:`, `FAIL:` and `SKIP` lines and report their
# readings with `report:`. Those go to the job log, where they are readable one
# lane at a time by whoever thinks to look. That surface does not let anyone ask
# the question this repository actually has open: which of these assertions is
# being made on four lanes when one would do.
#
# So each sheet carries its own lane's assertions, normalised -- prefix removed,
# every run of digits folded to `#`, whitespace collapsed -- and counted. Within
# one sheet that already shows repetition: an assertion that appears three times
# is one the lane is making three times. Across sheets it is a diff, which is
# why the same list is emitted again as JSON at the end of the page. Two lanes'
# digests intersected are the redundant set, and nothing before this round could
# produce that list at all.
#
# Normalising the digits is what makes the comparison possible and is also the
# one thing that could make it lie: two assertions differing only in a number
# collapse to one row here. That is the right trade for finding duplicates
# across lanes and the wrong one for reading a single result, so the raw lines
# stay in the logs below, whole.
ASSERTS="$(mktemp)"; PERLOG="$(mktemp)"
trap 'rm -f "$SHOTS" "$LOGS" "$ANIMS" "$STILLS" "$ASSERTS" "$PERLOG"' EXIT

while IFS= read -r log <&3; do
    [ -f "$log" ] || continue
    # `|| true` and not `|| echo 0`. grep -c prints its count *and* exits 1 when
    # that count is zero, so the obvious spelling appended a second line and
    # every field after the first log became a two-line string: the digest table
    # came out with sixty rows for sixteen logs, most of them named "0".
    count() { c="$(grep -acE "$1" "$2" 2>/dev/null || true)"; printf '%s' "${c:-0}"; }
    np="$(count '(^|[[:space:]])PASS:' "$log")"
    nf="$(count '(^|[[:space:]])FAIL:' "$log")"
    ns="$(count '(^|[[:space:]])SKIP' "$log")"
    nr="$(count '(^|[[:space:]])report:' "$log")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$log")" "$np" "$nf" "$ns" "$nr" >> "$PERLOG"
    # Two passes over the prefixes, not one. A suite that reports through
    # some suites write `report: PASS: the page asked for a window`, so a
    # single strip leaves `report: PASS:` on the front and the same assertion
    # made on two lanes -- one prefixed, one not -- would not compare equal.
    # Two passes is enough for every spelling in this tree and is portable in a
    # way a sed label loop is not.
    grep -ahE '(^|[[:space:]])(PASS|FAIL|SKIP):' "$log" 2>/dev/null |
        sed -E -e 's/^[[:space:]]*//' -e 's/^(report|PASS|FAIL|SKIP):[[:space:]]*//' |
        sed -E -e 's/^(report|PASS|FAIL|SKIP):[[:space:]]*//' \
               -e 's/[0-9]+/#/g' \
               -e 's/[[:space:]]+/ /g' \
               -e 's/[[:space:]]*$//' |
        tr -d '\000-\010\013\014\016-\037' >> "$ASSERTS"
done 3< "$LOGS"

N_ASSERT="$(wc -l < "$ASSERTS" | tr -d ' ')"
N_FAIL="$(awk -F'\t' '{n+=$3} END{print n+0}' "$PERLOG" 2>/dev/null || echo 0)"
N_DISTINCT="$(sort -u "$ASSERTS" 2>/dev/null | wc -l | tr -d ' ')"
echo "  sheet: lane=$LANE shots=$NSHOTS (${NANIM} burst frames) logs=$NLOGS -> $OUT"

mkdir -p "$(dirname "$OUT")"
{
cat <<HTMLHEAD
<!doctype html>
<meta charset="utf-8">
<title>$LANE — neutrino CI</title>
<style>
:root {
  color-scheme: light dark;
  --bg: #ffffff; --fg: #1c1c1e; --muted: #6b6b70;
  --card: #f6f6f7; --line: #dcdce0; --accent: #2b6cb0;
}
@media (prefers-color-scheme: dark) {
  :root { --bg:#16171a; --fg:#e8e8ea; --muted:#9a9aa2; --card:#1f2024; --line:#33343a; --accent:#78b4f0; }
}
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--fg);
       font:14px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; }
header { padding:22px 26px 16px; border-bottom:1px solid var(--line); }
h1 { margin:0 0 6px; font-size:20px; letter-spacing:-0.01em; }
.meta { color:var(--muted); font-size:12.5px; }
.meta code { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
main { padding:20px 26px 60px; }
h2 { font-size:13px; text-transform:uppercase; letter-spacing:.07em;
     color:var(--muted); margin:30px 0 12px; font-weight:600; }
.grid { display:grid; gap:16px; grid-template-columns:repeat(auto-fill,minmax(330px,1fr)); }
figure { margin:0; background:var(--card); border:1px solid var(--line);
         border-radius:9px; overflow:hidden; }
figure img { display:block; width:100%; height:auto; background:#0a0a0a; cursor:zoom-in; }
/* Clicking a picture makes it span every column of the grid, which is still
   narrower than the desktop these are captured at -- the browser scales it
   down, and the row it spans is where the detail is legible. In flow and
   not as a fixed overlay, because an overlay needs a second copy of the image
   and the pictures are the whole weight of this file: inlining each one twice
   put a 25-shot lane at 2.4 MB for 1.2 MB of pictures. */
figure:target { grid-column: 1 / -1; }
figure:target img { width:auto; max-width:100%; margin:0 auto; cursor:zoom-out; }
.close { display:none; }
figure:target .close { display:inline-block; margin-top:6px; font-size:12px;
                       color:var(--accent); text-decoration:none; }
figure:target .close::before { content:"\2190\00a0"; }
figcaption { padding:9px 12px 11px; }
.name { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
        font-size:12px; color:var(--accent); }
.what { font-size:12.5px; color:var(--fg); margin-top:2px; }
.what:empty::after { content:"no caption for this name yet"; color:var(--muted); font-style:italic; }
.size { font-size:11.5px; color:var(--muted); margin-top:3px; }
details { margin:8px 0; border:1px solid var(--line); border-radius:8px; background:var(--card); }
summary { padding:9px 12px; cursor:pointer; font-family:ui-monospace,Menlo,Consolas,monospace;
          font-size:12.5px; }
pre { margin:0; padding:12px; overflow-x:auto; font-size:11.5px; line-height:1.5;
      border-top:1px solid var(--line); }
.empty { color:var(--muted); font-style:italic; }
table.digest { border-collapse:collapse; font:12px/1.5 ui-monospace,Menlo,Consolas,monospace;
               margin-bottom:10px; }
table.digest th { text-align:left; font-weight:600; color:var(--muted);
                  padding:3px 14px 3px 0; border-bottom:1px solid var(--line); }
table.digest td { padding:2px 14px 2px 0; border-bottom:1px solid var(--line); }
table.digest td.bad { color:#d23; font-weight:700; }
/* A burst of frames, played back.
   The frames are laid end to end in a strip N times the width of the window
   that shows them, and the strip is stepped across by exactly one frame at a
   time -- so a steps() timing function and a translate of -100% is the whole
   animation, with no keyframe rule that has to know how many frames there are.
   (No backticks in this comment: it is inside an unquoted heredoc, where a
   backtick is a command substitution and not punctuation.) The two numbers
   that do depend on N are written inline by the generator below, which is why
   this block is the same for every burst on the page.
   Held still for a reader who has asked their system for that: the point of
   these frames is that they differ, and the first one is still a picture of the
   window. */
.flip { overflow:hidden; }
.reel { display:flex; animation-name:reel; animation-iteration-count:infinite;
        will-change:transform; }
.reel img { display:block; height:auto; background:#0a0a0a; }
@keyframes reel { from { transform:translateX(0); } to { transform:translateX(-100%); } }
@media (prefers-reduced-motion: reduce) { .reel { animation:none; } }
</style>
<header>
  <h1>$LANE</h1>
  <div class="meta">
    $NSHOTS picture(s), $NLOGS log(s), $N_ASSERT assertion(s), $N_FAIL failed
HTMLHEAD

if [ -n "${GITHUB_SHA:-}" ]; then
    printf '    &middot; <code>%s</code>\n' "$(printf '%s' "$GITHUB_SHA" | cut -c1-9)"
fi
if [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    printf '    &middot; <a href="https://github.com/%s/actions/runs/%s">run %s</a>\n' \
        "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID" "$GITHUB_RUN_ID"
fi
printf '    &middot; %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"

cat <<'HTMLMID'
  </div>
</header>
<main>
HTMLMID

if [ "$NSHOTS" = 0 ]; then
    echo '<p class="empty">This lane produced no pictures. That is a finding, not an empty page.</p>'
fi

# Grouped by the directory each came from, in the order the lane handed them
# over. The grouping is the lane's own: `screenshots` is what the suites took,
# `netinstall-screenshots` is what the installer suite took, and a reader
# looking for one is not helped by having them interleaved.
LAST_GROUP="__none__"
IDX=0
NOTPNG=""
# On fd 3, not stdin. A helper in the body that reads standard input would
# otherwise eat the rest of this list, which is exactly what the base64
# fallback above was doing.
while IFS="$(printf '\t')" read -r GROUP png <&3; do
    [ -f "$png" ] || continue
    if ! is_png "$png"; then
        NOTPNG="$NOTPNG$(basename "$png") -- $(wc -c < "$png" | tr -d ' ') bytes
"
        continue
    fi
    if [ "$GROUP" != "$LAST_GROUP" ]; then
        [ "$LAST_GROUP" = "__none__" ] || echo '</div>'
        printf '<h2>%s</h2>\n<div class="grid">\n' "$(printf '%s' "$GROUP" | esc)"
        LAST_GROUP="$GROUP"
    fi
    BASE="$(basename "$png" .png)"
    IDX=$((IDX + 1))
    BYTES="$(wc -c < "$png" | tr -d ' ')"
    printf '<figure id="shot%s">\n<a href="#shot%s"><img src="data:image/png;base64,%s" alt="%s"></a>\n' \
        "$IDX" "$IDX" "$(b64 "$png")" "$(printf '%s' "$BASE" | esc)"
    printf '<figcaption><div class="name">%s.png</div><div class="what">%s</div><div class="size">%s bytes</div><a class="close" href="#">back to the grid</a></figcaption>\n</figure>\n' \
        "$(printf '%s' "$BASE" | esc)" "$(subject "$BASE" | esc)" "$BYTES"
done 3< "$STILLS"
[ "$LAST_GROUP" = "__none__" ] || echo '</div>'

# The bursts, one figure each.
#
# A key is the label the lane gave the directory plus the name the frames share,
# so two lanes' worth in one sheet -- which no lane does today and one might --
# stay two animations. The frames of a key are contiguous in the list because
# the collection above sorted by path and the names differ only in their
# two-digit tail.
if [ -s "$ANIMS" ]; then
    KEYS="$(mktemp)"; FRAMES="$(mktemp)"
    awk -F'\t' '{ n = split($2, p, "/"); f = p[n];
                  sub(/-anim-[0-9]+\.png$/, "", f); print $1 "\t" f }' \
        "$ANIMS" | sort -u > "$KEYS"
    printf '<h2>Animation</h2>\n<div class="grid">\n'
    while IFS="$(printf '\t')" read -r GROUP PREFIX <&3; do
        awk -F'\t' -v g="$GROUP" -v pfx="$PREFIX" \
            '$1 == g && index($2, "/" pfx "-anim-") { print $2 }' \
            "$ANIMS" | sort > "$FRAMES"
        # Only the frames that are really PNGs, counted before any are written:
        # the strip's width and its step count both depend on how many there
        # are, and a frame dropped after the container was sized would leave the
        # last step of the loop on nothing.
        N=0
        while IFS= read -r png <&4; do
            is_png "$png" && N=$((N + 1))
        done 4< "$FRAMES"
        [ "$N" -gt 1 ] || continue
        # A fifth of a second a frame, which is slower than they were taken and
        # about as slow as a thing can be shown and still read as motion.
        # LC_ALL=C on both, and it is not decoration. awk's printf writes the
        # decimal separator its locale asks for, so on a machine set to a comma
        # locale these came out as "1,32s" and "16,6667%" -- which CSS parses as
        # nothing at all, leaving a strip of six full-width frames that never
        # moves. Measured on a pt_BR desktop; every CI lane runs under C and
        # would never have shown it.
        DUR="$(LC_ALL=C awk -v n="$N" 'BEGIN { printf "%.2f", n * 0.22 }')"
        WIDTH=$((N * 100))
        EACH="$(LC_ALL=C awk -v n="$N" 'BEGIN { printf "%.4f", 100 / n }')"
        printf '<figure>\n<div class="flip"><div class="reel" style="width:%s%%;animation-duration:%ss;animation-timing-function:steps(%s)">\n' \
            "$WIDTH" "$DUR" "$N"
        BYTES=0
        while IFS= read -r png <&4; do
            is_png "$png" || continue
            BYTES=$((BYTES + $(wc -c < "$png" | tr -d ' ')))
            printf '<img style="width:%s%%" src="data:image/png;base64,%s" alt="%s">\n' \
                "$EACH" "$(b64 "$png")" "$(printf '%s' "$PREFIX" | esc)"
        done 4< "$FRAMES"
        printf '</div></div>\n'
        printf '<figcaption><div class="name">%s-anim-01..%02d.png</div><div class="what">%s</div><div class="size">%s frames, %s bytes</div></figcaption>\n</figure>\n' \
            "$(printf '%s' "$PREFIX" | esc)" "$N" \
            "$(printf 'The same window over %s frames about a tenth of a second apart -- what the indicator does, rather than what it looked like once' "$N" | esc)" \
            "$N" "$BYTES"
    done 3< "$KEYS"
    echo '</div>'
    rm -f "$KEYS" "$FRAMES"
fi

# Named, never dropped. A file a step meant to be a picture and that is not one
# is a finding about that step, and silence here would hide it twice.
if [ -n "$NOTPNG" ]; then
    printf '<h2>Not pictures</h2>\n<p class="empty">Collected as screenshots, carrying no PNG signature:</p>\n<pre>'
    printf '%s' "$NOTPNG" | esc
    printf '</pre>\n'
fi

if [ "$N_ASSERT" != 0 ]; then
    printf '<h2>What this lane asserted</h2>\n'
    printf '<table class="digest"><thead><tr><th>log</th><th>pass</th><th>fail</th><th>skip</th><th>readings</th></tr></thead><tbody>\n'
    while IFS="$(printf '\t')" read -r nm np nf ns nr <&3; do
        cls=""
        [ "$nf" != 0 ] && cls=' class="bad"'
        printf '<tr><td>%s</td><td>%s</td><td%s>%s</td><td>%s</td><td>%s</td></tr>\n' \
            "$(printf '%s' "$nm" | esc)" "$np" "$cls" "$nf" "$ns" "$nr"
    done 3< "$PERLOG"
    printf '</tbody></table>\n'

    # Sorted by count, because the question this answers is "what is this lane
    # doing more than once" and the answer is at the top of that order.
    printf '<details><summary>every assertion, normalised &mdash; %s distinct of %s</summary><pre>' \
        "$N_DISTINCT" "$N_ASSERT"
    sort "$ASSERTS" | uniq -c | sort -rn |
        sed -E 's/^ *([0-9]+) /\1\t/' | esc
    printf '</pre></details>\n'
fi

if [ "$NLOGS" != 0 ]; then
    echo '<h2>Logs</h2>'
    while IFS= read -r log <&3; do
        [ -f "$log" ] || continue
        printf '<details><summary>%s &mdash; %s lines</summary><pre>' \
            "$(basename "$log" | esc)" "$(wc -l < "$log" | tr -d ' ')"
        # Bounded, and from the end. A verifier log is a few hundred lines and
        # belongs here whole; appcache.ps1 has produced twenty thousand, and
        # sixteen of those would be more of this file than the pictures are.
        # The tail rather than the head: the settled marks and the totals are
        # the last lines, and dropping from the end throws away exactly the part
        # worth reading.
        tail -c 60000 "$log" | esc
        echo '</pre></details>'
    done 3< "$LOGS"
fi

echo '</main>'
} > "$OUT"

# The same list again, for a reader that is not a person.
#
# A sheet answers for one lane; the redundancy question is about the set of
# them, and the only way to intersect eight lanes is to have eight machine
# -readable lists. Emitted last and inside a script block so it is invisible on
# the page and one `sed` away from whoever wants it.
{
    printf '<script type="application/json" id="nt-digest">\n{'
    printf '"lane":"%s","sha":"%s","run":"%s",' \
        "$LANE" "${GITHUB_SHA:-}" "${GITHUB_RUN_ID:-}"
    printf '"shots":%s,"frames":%s,"logs":%s,"assertions":%s,"distinct":%s,"failures":%s,' \
        "$NSHOTS" "$NANIM" "$NLOGS" "$N_ASSERT" "$N_DISTINCT" "$N_FAIL"
    printf '"asserted":['
    sort "$ASSERTS" | uniq -c | sort -rn |
        sed -E -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/</\\u003c/g' \
               -e 's/^ *([0-9]+) (.*)$/{"n":\1,"t":"\2"},/' |
        tr -d '\n' | sed -E 's/,$//'
    printf ']}\n</script>\n'
} >> "$OUT"


echo "  sheet: $(wc -c < "$OUT" | tr -d ' ') bytes written"
