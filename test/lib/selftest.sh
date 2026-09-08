#!/bin/bash
# selftest.sh - the harness, and the verifiers on top of it, run with no display.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Usage: bash test/lib/selftest.sh
#
# Everything in test/ that watches a window has until now been exercised only by
# CI, because running it needed a display, a toolkit and a real app -- eighteen
# minutes to find out whether a refactor of an assertion still said the same
# thing. This runs the verifier itself against stub instruments: `xdotool` and
# friends come off a PATH this script controls and replay a scripted window,
# so what is under test is the verifier's arithmetic and its reporting, which is
# the half that has no business needing a desktop.
#
# It is the same technique lanes.sh uses on the engine walk, pointed at the
# other end of the suite. What it cannot check is whether xdotool really says
# what the stub says it does; that is CI's job and stays CI's job.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
nt_python() { command -v python3 >/dev/null 2>&1 && echo python3 || echo python; }
ok()   { echo "  PASS: $*"; }
bad()  { echo "  FAIL: $*"; FAILED=$((FAILED + 1)); }

# ------------------------------------------------------------------ the harness

echo "### harness.sh"

(
    export NT_LANE=selftest NT_SUITE=unit NT_RESULTS="$WORK/unit.tsv"
    # shellcheck source=/dev/null
    . "$ROOT/test/lib/harness.sh"
    set -euo pipefail
    nt_pass a.one "held"
    nt_fail a.two "broke"
    nt_skip a.three "not here"
    nt_eq   a.four  "n" 1 1
    nt_eq   a.five  "n" 1 2
    nt_match a.six  "g" "sans-serif" "*serif*"
    nt_report "a reading"
    echo "$NT_PASSES $NT_FAILURES $NT_SKIPS" > "$WORK/counters"
) > "$WORK/unit.out" 2>&1

read -r p f s < "$WORK/counters"
[ "$p:$f:$s" = "3:2:1" ] && ok "counters ($p pass, $f fail, $s skip)" \
    || bad "counters expected 3:2:1 actual=$p:$f:$s"

# A failing assertion must not end a suite that runs under `set -e`. If it does,
# the totals line -- the one thing a reader needs -- is what gets lost.
grep -q "a reading" "$WORK/unit.out" \
    && ok "a failed assertion did not abort the suite" \
    || bad "the suite stopped at the first failure; nothing after it ran"

# `| tr -d ' '` and not a bare wc: BSD wc pads its count with leading spaces,
# so the obvious spelling compares "       6" against "6" and fails on macOS
# while passing on Linux. Every other wc in this tree already carries the tr,
# which is how the omission here was worth finding.
NT_ROWS="$(wc -l < "$WORK/unit.tsv" | tr -d ' ')"
[ "$NT_ROWS" = "6" ] \
    && ok "six rows for six assertions" \
    || bad "expected 6 rows, got $NT_ROWS"

# The reading must not be filed as a case. Every row in the matrix has to be
# something that can be true or false, and `report:` lines are not.
grep -q "a reading" "$WORK/unit.tsv" \
    && bad "a report: line reached the results file as a case" \
    || ok "readings stay out of the results file"

# Five columns, always. A tab inside a detail string would move every column
# after it, which is why nt_clean exists.
(
    export NT_LANE=selftest NT_SUITE=tabs NT_RESULTS="$WORK/tabs.tsv"
    . "$ROOT/test/lib/harness.sh"
    nt_pass b.one "$(printf 'a\tb')"
) >/dev/null 2>&1
[ "$(awk -F'\t' '{print NF}' "$WORK/tabs.tsv")" = "5" ] \
    && ok "a tab in a detail string does not add a column" \
    || bad "a tab in a detail string moved the columns"

# Prose only, when nothing asked for rows. A developer running one suite in a
# terminal should not have a results file appear beside it.
(
    unset NT_RESULTS NT_RESULTS_DIR
    export NT_LANE=selftest NT_SUITE=prose
    . "$ROOT/test/lib/harness.sh"
    nt_pass c.one "held"
) > "$WORK/prose.out" 2>&1
grep -q "  PASS: held" "$WORK/prose.out" \
    && ok "prose still works with no results file configured" \
    || bad "the stdout channel needs NT_RESULTS, and it must not"

# ---------------------------------------------------------------- the verifier

echo
echo "### verify-linux.sh against stub instruments"

# Only where that verifier could run for real.
#
# verify-linux.sh reads geometry with `grep -oP`, which is GNU-only -- the BSD
# grep macOS ships has no -P at all -- and it reaches for xdotool and xprop,
# which are X11. It is a Linux verifier by name and by design, and there is a
# verify-macos.sh for the other platform.
#
# The harness above is different and is checked everywhere, because every lane
# sources it. This half is skipped rather than quietly dropped: a section that
# vanishes on a platform looks exactly like a section that passed there, which
# is the distinction nt_skip exists to make and it would be poor form for this
# file to not make it about itself.
# A flag and not an early exit. The first spelling of this returned from the
# whole file, which took the recorded-run replay below out with it -- so macOS
# ran six checks, said Total: 0, and looked exactly like a platform where all of
# it had passed. A skip that skips more than it says it does is worse than no
# skip at all.
NT_HAVE_GREP_P=1
if ! echo x | grep -oP 'x' >/dev/null 2>&1; then
    NT_HAVE_GREP_P=0
    echo "  SKIP: verify-linux.sh needs GNU grep -oP, which this platform has not"
fi

if [ "$NT_HAVE_GREP_P" = 1 ]; then

BIN="$WORK/bin"; STATE="$WORK/state"; mkdir -p "$BIN" "$STATE"

# The scripted window. One title per state, in the order neutrinotest.js drives
# them, and the stub hands each one out twice: once to the wait that is looking
# for it and once to the assertion that re-reads it. Advancing on every call
# instead would mean assert_title always saw the state after the one it had just
# waited for -- which is a bug this file exists to not have.
cat > "$STATE/titles" <<'TITLES'
neutrino
STEP0
STEP1-Test Title
STEP2
STEP3
THEMEOK
FONTOK
TESTS DONE
TITLES
echo 1 > "$STATE/idx"
echo 0 > "$STATE/seen"

mkxdotool() {
    cat > "$BIN/xdotool" <<XDO
#!/bin/bash
STATE="$STATE"
case "\$1" in
    getwindowname)
        idx="\$(cat "\$STATE/idx")"; seen="\$(cat "\$STATE/seen")"
        sed -n "\${idx}p" "\$STATE/titles"
        seen=\$((seen + 1))
        if [ "\$seen" -ge 2 ]; then
            echo \$((idx + 1)) > "\$STATE/idx"; echo 0 > "\$STATE/seen"
        else
            echo "\$seen" > "\$STATE/seen"
        fi
        ;;
    getwindowgeometry)
        echo "Window 1"
        echo "  Position: 0,37 (screen: 0)"
        echo "  Geometry: $1"
        ;;
    search) exit 1 ;;
esac
XDO
    chmod +x "$BIN/xdotool"
}
mkxdotool 500x400

cat > "$BIN/xprop" <<'XPROP'
#!/bin/bash
case "$*" in
    *_NET_CLIENT_LIST*)        echo "_NET_CLIENT_LIST(WINDOW): window id # 0x1" ;;
    *_NET_SUPPORTING_WM_CHECK*) echo "_NET_SUPPORTING_WM_CHECK(WINDOW): window id # 0x2" ;;
    *_NET_WM_NAME*)            echo '_NET_WM_NAME(UTF8_STRING) = "metacity"' ;;
    *_NET_FRAME_EXTENTS*)      echo "_NET_FRAME_EXTENTS(CARDINAL) = 0, 0, 37, 0" ;;
esac
XPROP

# Absolute 0,37 with a 37-row title bar above it puts the frame at 0,0, which is
# where the app asked to be. Parent differs from root, so the window is framed.
cat > "$BIN/xwininfo" <<'XWIN'
#!/bin/bash
echo "  Absolute upper-left X:  0"
echo "  Absolute upper-left Y:  37"
echo "  Relative upper-left X:  0"
echo "  Relative upper-left Y:  37"
case "$*" in *-tree*)
    echo "  Root window id: 0x9 (the root window)"
    echo "  Parent window id: 0x5"
esac
XWIN

# A real script and not an empty file. `: > import` leaves a zero-byte
# executable, which bash on Linux runs as an empty script and other shells are
# entitled to refuse -- and a stub that cannot be executed is a screenshot call
# that fails rather than one that does nothing.
printf '#!/bin/bash\nexit 0\n' > "$BIN/import"
chmod +x "$BIN"/*

RESULTS="$WORK/walk.tsv"
PATH="$BIN:$PATH" NT_LANE=selftest NT_RESULTS="$RESULTS" NT_WAIT_TIMEOUT=5 \
    bash "$ROOT/test/verify-linux.sh" "$WORK/shots" > "$WORK/walk.out" 2>&1
RC=$?

[ "$RC" = "0" ] && ok "a clean walk exits 0" \
    || { bad "a clean walk exited $RC"; sed 's/^/      /' "$WORK/walk.out"; }

for c in walk.window.appeared walk.step0.reached walk.title walk.resize \
         walk.move walk.theme.readable walk.fonts.readable walk.done; do
    n="$(awk -F'\t' -v c="$c" '$3 == c' "$RESULTS" 2>/dev/null | wc -l | tr -d ' ')"
    v="$(awk -F'\t' -v c="$c" '$3 == c { print $4 }' "$RESULTS" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')"
    if [ "$n" = "1" ] && [ "$v" = "PASS" ]; then
        ok "$c reported once, PASS"
    else
        bad "$c reported $n row(s), verdict(s) '${v:-none}' -- wanted exactly one PASS"
    fi
done

# The walk again, with the instrument reporting a window that never took the
# size it was asked for. Without this the section above proves only that the
# verifier can be made to say PASS -- an assertion deleted outright would pass
# it just as happily, which is the one regression a suite like this exists to
# catch.
echo 1 > "$STATE/idx"; echo 0 > "$STATE/seen"
mkxdotool 640x480
BAD="$WORK/bad.tsv"
PATH="$BIN:$PATH" NT_LANE=selftest NT_RESULTS="$BAD" NT_WAIT_TIMEOUT=5 \
    bash "$ROOT/test/verify-linux.sh" "$WORK/shots-bad" > "$WORK/bad.out" 2>&1
BRC=$?

[ "$BRC" = "1" ] && ok "a wrong size exits 1 (one failed case)" \
    || bad "a wrong size exited $BRC, wanted 1"
[ "$(awk -F'\t' '$3 == "walk.resize" { print $4 }' "$BAD")" = "FAIL" ] \
    && ok "walk.resize reports FAIL when the window is the wrong size" \
    || bad "walk.resize did not fail on a 640x480 window asked to be 500x400"
# The rest of the walk still has to be reported. A suite that stops at its first
# failure tells you one thing was wrong and nothing about what else was.
[ "$(awk -F'\t' '$3 == "walk.done" { print $4 }' "$BAD")" = "PASS" ] \
    && ok "one failed case does not stop the cases after it" \
    || bad "the walk stopped after the failure; later cases went unreported"
mkxdotool 500x400

fi   # NT_HAVE_GREP_P

echo
echo "### analyse.sh against the recorded runs"

# The records in test/lib/records are real: they came out of the last green run
# on main, five probes on each of five lanes, and each one is what that lane's
# sampler actually wrote. Replaying them is the only way to exercise the
# analysers without a desktop, a toolkit and a two-minute app launch -- and it
# is what made moving them out of verify-std.sh checkable rather than hopeful.
#
# windows-content's five are the ones worth having. They were sampled by
# PowerShell, carry six columns rather than seven, and are analysed here by the
# same bash that analyses the X11 lanes'. If that ever stops working, this is
# where it says so.
RECDIR="$ROOT/test/lib/records"
if [ -d "$RECDIR" ]; then
    NREC=0; BADREC=0
    for rec in "$RECDIR"/*.tsv; do
        [ -f "$rec" ] || continue
        base="$(basename "$rec" .tsv)"; probe="${base##*.}"
        rrows="$WORK/rec-$base.tsv"
        NT_LANE="${base%%.*}" NT_SUITE=verify-std NT_RESULTS="$rrows" \
            bash "$ROOT/test/verify-std.sh" "$probe" "$WORK/shots-rec" "$rec" \
            > "$WORK/rec-$base.out" 2>&1
        rrc=$?
        NREC=$((NREC + 1))
        [ "$rrc" = "0" ] || { bad "$base replayed with rc=$rrc"; BADREC=$((BADREC + 1)); }
        [ -s "$rrows" ] || { bad "$base filed no rows"; BADREC=$((BADREC + 1)); }
        # One verdict per case per lane. Two rows for one id put two answers in
        # one cell of the grid, which is a defect in the suite and not in the
        # grid -- open-target was exactly that until its id took the target.
        dup="$(awk -F'\t' '{print $3}' "$rrows" 2>/dev/null | sort | uniq -d | tr '\n' ' ')"
        [ -z "$dup" ] || { bad "$base filed a case twice: $dup"; BADREC=$((BADREC + 1)); }
        # And every id it actually filed is registered. This is the half that
        # catches an id built from a variable -- `std.win.open-target.$v` is one
        # id in the source and two at runtime, and only the rows know which two.
        while IFS= read -r rid; do
            [ -n "$rid" ] || continue
            grep -q "^$rid	" "$ROOT/test/cases.tsv" ||
                { bad "$base filed unregistered case '$rid'"; BADREC=$((BADREC + 1)); }
        done < <(awk -F'\t' '{print $3}' "$rrows" 2>/dev/null | sort -u)
    done
    [ "$BADREC" = 0 ] && ok "$NREC recorded run(s) replay clean and file one row per case"

    # Every id the analysers can emit, against the registry. Static, so a case
    # id that no record happens to reach is still checked.
    # The literal ids, statically, so one that no record happens to reach is
    # still checked. Ids built from a variable are skipped here and caught
    # above instead, off the rows they actually produced -- the source cannot
    # say what `std.win.open-target.$v` expands to and should not guess.
    MISSING=""
    for id in $(grep -oE 'ctl_(pass|fail|skip) [a-z][a-z0-9.-]*' "$ROOT/test/lib/analyse.sh" |
                awk '{print $2}' | sort -u); do
        case "$id" in *'.'*) ;; *) continue ;; esac
        grep -q "^$id	" "$ROOT/test/cases.tsv" || MISSING="$MISSING $id"
    done
    [ -z "$MISSING" ] && ok "every literal case id in analyse.sh is registered" \
        || bad "in analyse.sh but not cases.tsv:$MISSING"
else
    echo "  SKIP: no recorded runs at test/lib/records"
fi

echo
# Every id a suite emits has to be in the registry, or the matrix has a column
# nobody declared and no way to tell a typo from a new case.
UNREG=""
while IFS= read -r id; do
    grep -q "^$id	" "$ROOT/test/cases.tsv" || UNREG="$UNREG $id"
done < <(awk -F'\t' '{print $3}' "$RESULTS" | sort -u)
[ -z "$UNREG" ] && ok "every case id emitted is registered in cases.tsv" \
    || bad "emitted but not in cases.tsv:$UNREG"

echo
echo "### sheet.sh, and the digest the grid reads"

# The macOS lane published a sheet that looked perfect and was silently absent
# from the cross-lane grid for a whole round, because `sed 's/\t/'` is a tab on
# GNU sed and a literal `t` on the BSD sed macOS ships -- so the substitution
# that formats the cases array never matched there and the digest was invalid
# JSON. matrix.py said so, to stderr, in a job nobody reads unless the grid
# looks wrong; and the grid looking wrong is a column being absent, which is
# exactly what it looked like.
#
# So the digest is parsed here, on whatever platform is running, before anything
# depends on it.
SHEETSRC="$WORK/sheetsrc"; mkdir -p "$SHEETSRC"
(
    export NT_LANE=selftest NT_SUITE=verify-std NT_RESULTS="$SHEETSRC/rows.tsv"
    . "$ROOT/test/lib/harness.sh"
    nt_pass sheet.probe.a "a control that held"
    nt_skip sheet.probe.b "a control this lane cannot ask"
    nt_fail sheet.probe.c "a control that did not hold"
) >/dev/null 2>&1
printf '  PASS: a prose assertion 12 times\n  FAIL: a prose failure\n' > "$SHEETSRC/old.log"
bash "$ROOT/test/sheet.sh" selftest "$WORK/sheet.html" "Logs=$SHEETSRC" >/dev/null 2>&1

if "$(nt_python 2>/dev/null || echo python3)" - "$WORK/sheet.html" <<'PYEOF' 2>/dev/null
import json, re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'id="nt-digest">\s*(\{.*?\})\s*</script>', h, re.S)
if not m:
    sys.exit(1)
d = json.loads(m.group(1))
ids = sorted(c["id"] for c in d.get("cases", []))
v = {c["id"]: c["v"] for c in d.get("cases", [])}
ok = (ids == ["sheet.probe.a", "sheet.probe.b", "sheet.probe.c"]
      and v["sheet.probe.a"] == "PASS" and v["sheet.probe.b"] == "SKIP"
      and v["sheet.probe.c"] == "FAIL")
sys.exit(0 if ok else 1)
PYEOF
then
    ok "the sheet's digest parses and carries the three verdicts"
else
    bad "the sheet's digest does not parse, or lost a case -- the grid would drop this lane"
fi

echo
echo "### the registry, against every suite that speaks to it"

# Static, and across the whole tree. The runtime checks above only cover suites
# this machine can run: verify-macos.sh needs a Mac and verify-std.ps1 needs
# Windows, and an id either of them misspells would otherwise be found by CI on
# the one lane that runs it, which is the slowest way to learn it.
# Comment lines are stripped first, and this file is skipped. Both were found
# the same way: the scan reported `analyse.sh:are`, out of a comment reading
# "its nt_pass/nt_fail are not used here", and every fixture id this file
# invents to test the harness with.
UNKNOWN=""
for suite in "$ROOT"/test/*.sh "$ROOT"/test/lib/*.sh; do
    case "$(basename "$suite")" in selftest.sh) continue ;; esac
    grep -q 'harness\.sh' "$suite" 2>/dev/null || continue
    for id in $(sed 's/#.*//' "$suite" |
                grep -oE '\bnt_(pass|fail|skip) "?[a-z][a-z0-9.-]*' |
                awk '{print $2}' | tr -d '"' | sort -u); do
        # An id has a dot in it. A bare word is a variable or a fragment.
        case "$id" in *.*) ;; *) continue ;; esac
        grep -q "^$id	" "$ROOT/test/cases.tsv" ||
            UNKNOWN="$UNKNOWN $(basename "$suite"):$id"
    done
done
[ -z "$UNKNOWN" ] && ok "every literal case id in every suite is registered" \
    || bad "emitted but not in cases.tsv:$UNKNOWN"

# And the other direction. A registry that accumulates ids nothing emits stops
# being able to tell a hole from a leftover, which is the one thing it is for.
# The suites, listed once. `grep -r --include` would do it in one line and is
# the sort of thing that turns out to mean something slightly different on the
# BSD grep macOS ships -- and the failure mode there is every id reported as an
# orphan, which reads as a catastrophe rather than as a portability note.
NT_SUITES="$(ls "$ROOT"/test/*.sh "$ROOT"/test/lib/*.sh 2>/dev/null | grep -v 'selftest\.sh$')"

ORPHAN=""
while IFS="$(printf '\t')" read -r rid _rest; do
    # The carriage return is stripped before the guard, not after it. On a
    # Windows checkout cases.tsv arrives CRLF, so a blank line reads as a lone
    # \r -- which is neither empty nor a comment, and went through as an id
    # whose whole name is invisible. The report read
    # "in cases.tsv but emitted nowhere: " with nothing after the colon, which
    # is the least actionable failure this file could produce.
    rid="$(printf '%s' "$rid" | tr -d '\r')"
    case "$rid" in ''|'#'*) continue ;; esac
    # An id whose last segment is built at runtime -- `std.win.open-target.$v`
    # is one call site and two ids -- cannot be found by its whole name, so the
    # stem followed by a variable counts as emitting it.
    stem="${rid%.*}"
    found=0
    for suite in $NT_SUITES; do
        if grep -qE "(nt|ctl)_(pass|fail|skip) \"?($rid|$stem\.\\\$)" "$suite" 2>/dev/null; then
            found=1; break
        fi
    done
    [ "$found" = 1 ] || ORPHAN="$ORPHAN $rid"
done < "$ROOT/test/cases.tsv"
[ -z "$ORPHAN" ] && ok "every registered case id is emitted by some suite" \
    || bad "in cases.tsv but emitted nowhere:$ORPHAN"

# --------------------------------------------------------------------- run.sh

echo
echo "### run.sh, and the manifest it reads"

# The manifest, checked without running anything on it. A typo in a lane name or
# an artifact name is a suite that silently does not run, and the run it does not
# happen in is a green one -- so this is the half worth catching at a desk.

RUNSH="$ROOT/test/run.sh"
SUITES_TSV="$ROOT/test/suites.tsv"
APPS_TSV="$ROOT/test/apps.tsv"

# Column shape. A row with the wrong number of columns puts a command in the
# setup column, where it is reported as an unknown directive -- a sentence about
# a directive, for a defect about a tab.
BADCOLS="$(awk -F'\t' '!/^#/ && NF { if (NF < 3 || NF > 4) print FILENAME ":" FNR }' \
    "$SUITES_TSV")"
[ -z "$BADCOLS" ] && ok "every suites.tsv row has three or four columns" \
    || bad "suites.tsv rows with the wrong column count:$(echo $BADCOLS)"

BADCOLS="$(awk -F'\t' '!/^#/ && NF && NF != 4 { print FILENAME ":" FNR }' "$APPS_TSV")"
[ -z "$BADCOLS" ] && ok "every apps.tsv row has four columns" \
    || bad "apps.tsv rows with the wrong column count:$(echo $BADCOLS)"

# Every artifact a suite asks for is declared, and every declared artifact is
# asked for. Both directions, for the reason the registry scan below runs both:
# an artifact nobody builds is a row nobody reads, and an artifact nobody
# declared is a lane that fails at the point it was supposed to start measuring.
APPNAMES="$(awk -F'\t' '!/^#/ && NF { print $1 }' "$APPS_TSV")"
# awk and not `sed -n 's/^\(app\|build\)=//p'`: `\|` is GNU's alternation and
# BSD sed reads it as a literal, so on macOS that expression matched nothing and
# this list came back empty -- which made the next check report all five
# artifacts as unused. The first thing the macos lane caught.
WANTED_APPS="$(awk -F'\t' '!/^#/ && NF { print $3 }' "$SUITES_TSV" |
    tr ' ' '\n' |
    awk '/^(app|build)=/ { sub(/^(app|build)=/, ""); print }' | sort -u)"

MISSING=""
for a in $WANTED_APPS; do
    case " $(echo $APPNAMES) " in *" $a "*) ;; *) MISSING="$MISSING $a" ;; esac
done
[ -z "$MISSING" ] && ok "every artifact a suite names is declared in apps.tsv" \
    || bad "named by a suite and not in apps.tsv:$MISSING"

UNUSED=""
for a in $APPNAMES; do
    case " $(echo $WANTED_APPS) " in *" $a "*) ;; *) UNUSED="$UNUSED $a" ;; esac
done
[ -z "$UNUSED" ] && ok "every artifact in apps.tsv is named by some suite" \
    || bad "in apps.tsv and named by nothing:$UNUSED"

# The sources exist. mkapp.sh would say so too, but it would say it on a runner
# eight minutes into a lane rather than here.
MISSING=""
while IFS="$(printf '\t')" read -r name builder source flags; do
    case "$name" in \#*|"") continue ;; esac
    [ "$builder" = "mkapp" ] || continue
    [ -f "$ROOT/test/$source" ] || MISSING="$MISSING $source"
done < "$APPS_TSV"
[ -z "$MISSING" ] && ok "every mkapp source in apps.tsv is on disk" \
    || bad "named in apps.tsv and not on disk:$MISSING"

# Every lane in the manifest is a job in the workflow. A lane key that is not a
# job is rows nobody will ever run, and it looks identical to rows that ran green.
LANES="$(awk -F'\t' '!/^#/ && NF { sub(/:.*/, "", $1); print $1 }' "$SUITES_TSV" | sort -u)"
JOBS="$(sed -n 's/^  \([a-z0-9-]*\):$/\1/p' "$ROOT/.github/workflows/ci.yml")"
STRAY=""
for l in $LANES; do
    case " $(echo $JOBS) " in *" $l "*) ;; *) STRAY="$STRAY $l" ;; esac
done
[ -z "$STRAY" ] && ok "every lane in suites.tsv is a job in ci.yml" \
    || bad "in suites.tsv and not a job in ci.yml:$STRAY"

# No suite is run twice: once from the manifest and once by a hand-written step.
# This is what makes a half-migrated lane safe, and it is the check that stops
# the migration quietly double-running a suite for a whole round.
DOUBLED=""
for l in $LANES; do
    for sname in $(bash "$RUNSH" --list "$l" 2>/dev/null); do
        # The lane's own run.sh invocations name the suites it has migrated.
        awk -v lane="$l" -v s="$sname" '
            /^  [a-z0-9-]+:$/ { j = $1; sub(/:$/, "", j) }
            j == lane && /test\/run\.sh/ { print }
        ' "$ROOT/.github/workflows/ci.yml" | grep -qE "[ ]$sname([ ]|$)" || continue
        # It is migrated. It must not also appear as a bare step.sh line.
        awk -v lane="$l" '
            /^  [a-z0-9-]+:$/ { j = $1; sub(/:$/, "", j) }
            j == lane && /test\/step\.sh/ { print }
        ' "$ROOT/.github/workflows/ci.yml" | grep -qE -- "--log $sname([ ]|$)" &&
            DOUBLED="$DOUBLED $l/$sname"
    done
done
[ -z "$DOUBLED" ] && ok "no lane runs a migrated suite from both the manifest and a step" \
    || bad "run from the manifest and from a hand-written step:$DOUBLED"

# --dry-run resolves for every lane, and what it prints parses back through
# step.sh's own option loop. A directive that produced a flag step.sh does not
# take would otherwise be found by a runner.
for l in $(awk -F'\t' '!/^#/ && NF { print $1 }' "$SUITES_TSV" | sort -u); do
    out="$(bash "$RUNSH" --dry-run "$l" 2>&1)"
    if [ -z "$out" ]; then
        bad "run.sh --dry-run $l printed nothing"
        continue
    fi
    unknown="$(printf '%s' "$out" | grep -c 'unknown' || true)"
    [ "$(printf '%s' "$unknown" | tr -d ' ')" = 0 ] ||
        bad "run.sh --dry-run $l reported an unknown directive"
done
ok "run.sh --dry-run resolves every lane in the manifest"

# The arithmetic, against a fixture manifest. No display, no app, no artifact:
# what is under test is that a lane adds up and that a suite cannot hide.
FIXBIN="$WORK/runbin"; mkdir -p "$FIXBIN"
for n in 0 2 3; do
    printf '#!/bin/sh\nexit %s\n' "$n" > "$FIXBIN/ntexit$n"
    chmod +x "$FIXBIN/ntexit$n"
done
FIXTSV="$WORK/fixture-suites.tsv"
{
    printf 'fixture\t*\ttimeout=20\n'
    printf 'fixture\tgreen\t-\tntexit0\n'
    printf 'fixture\tthree\t-\tntexit3\n'
    printf 'fixture\ttwo\t-\tntexit2\n'
} > "$FIXTSV"

FIXOUT="$(PATH="$FIXBIN:$PATH" NT_SUITES_FILE="$FIXTSV" bash "$RUNSH" fixture 2>&1)"
FIXRC=$?
[ "$FIXRC" = 5 ] && ok "run.sh exits the lane's failure count (0+3+2 = 5)" \
    || bad "run.sh exited $FIXRC for a fixture lane totalling 5 failures"

# A green suite behind a red one still runs. In YAML that was `if: always()` on
# every step; here it is the runner's job, and a runner that stopped at the first
# red would quietly take every reading behind it with it.
printf '%s' "$FIXOUT" | grep -q '::group::two' &&
    ok "a suite behind a failing one still runs" ||
    bad "run.sh stopped at the first failing suite"

# The timing table has a line per suite that ran.
FIXTIMES="$(printf '%s' "$FIXOUT" | sed -n '/Where the time went/,/Total:/p' |
    grep -c 's  ' || true)"
[ "$(printf '%s' "$FIXTIMES" | tr -d ' ')" = 3 ] &&
    ok "the timing table has one line per suite that ran" ||
    bad "the timing table had $FIXTIMES lines for three suites"

# The leash, and that it is spoken rather than anonymous. This is the one that
# matters on macOS, where there is no timeout(1) and step.sh's watchdog is the
# only thing behind a declared bound.
LEASHTSV="$WORK/fixture-leash.tsv"
{
    printf 'fixture\t*\ttimeout=2\n'
    printf 'fixture\twedged\t-\tsleep 30\n'
    printf 'fixture\tafter\t-\tntexit0\n'
} > "$LEASHTSV"
LEASHOUT="$(PATH="$FIXBIN:$PATH" NT_SUITES_FILE="$LEASHTSV" bash "$RUNSH" fixture 2>&1)"
LEASHRC=$?
printf '%s' "$LEASHOUT" | grep -q 'exceeded its 2s leash' &&
    ok "a suite past its leash is killed and says so" ||
    bad "a suite past its leash was not reported as such"
printf '%s' "$LEASHOUT" | grep -q '::group::after' &&
    ok "the suite behind a leashed one still runs" ||
    bad "a leashed suite took the rest of the lane with it"
[ "$LEASHRC" = 1 ] && ok "a leashed suite counts as one failure, not 124" \
    || bad "a leashed lane exited $LEASHRC rather than 1"

# An unknown directive is an error. A typo silently ignored is a suite running
# without the display it asked for.
BADTSV="$WORK/fixture-bad.tsv"
printf 'fixture\toops\tnosuchdirective\tntexit0\n' > "$BADTSV"
BADOUT="$(PATH="$FIXBIN:$PATH" NT_SUITES_FILE="$BADTSV" bash "$RUNSH" fixture 2>&1)"
printf '%s' "$BADOUT" | grep -q "unknown setup directive 'nosuchdirective'" &&
    ok "an unknown setup directive is refused by name" ||
    bad "an unknown setup directive was not refused"

# The selection, which is what keeps a half-migrated lane from double-running.
SELOUT="$(PATH="$FIXBIN:$PATH" NT_SUITES_FILE="$FIXTSV" bash "$RUNSH" fixture two 2>&1)"
printf '%s' "$SELOUT" | grep -q '::group::two' &&
    ! printf '%s' "$SELOUT" | grep -q '::group::green' &&
    ok "a selection runs only the rows it names" ||
    bad "a selection did not restrict the rows that ran"

# An empty setup column. Tab is IFS whitespace and bash collapses a run of it, so
# `suite<TAB><TAB>command` reaches read as two fields and the command lands in
# the setup variable. It cost a round to find; it does not get to come back.
printf '%s' "$FIXOUT" | grep -q 'unknown setup directive' &&
    bad "a row with an empty setup column was misread as a directive" ||
    ok "a row with an empty setup column keeps its command"

# ------------------------------------------------- the workflow lint, which ran nowhere

echo
echo "### workflow-lint.py"

if command -v "$(nt_python)" >/dev/null 2>&1; then
    # This lint has existed since it was written and nothing has ever run it --
    # not ci.yml, not this file. It encodes rules a YAML parser will not catch,
    # one of which cost exactly one round to find out.
    if "$(nt_python)" "$ROOT/test/lib/workflow-lint.py" "$ROOT"/.github/workflows/*.yml; then
        ok "workflow-lint.py is satisfied with .github/workflows"
    else
        bad "workflow-lint.py reported problems"
    fi
else
    echo "  SKIP: no python3 on this machine, so workflow-lint.py did not run"
fi

echo
echo "### Total: $FAILED failure(s)"
exit "$FAILED"
