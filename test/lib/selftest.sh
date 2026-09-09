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
    bash "$ROOT/test/suite/verify-linux.sh" "$WORK/shots" > "$WORK/walk.out" 2>&1
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
    bash "$ROOT/test/suite/verify-linux.sh" "$WORK/shots-bad" > "$WORK/bad.out" 2>&1
BRC=$?

[ "$BRC" = "1" ] && ok "a wrong size exits 1 (one failed case)" \
    || bad "a wrong size exited $BRC, wanted 1"
[ "$(awk -F'\t' '$3 == "walk.resize" { print $4 }' "$BAD")" = "FAIL" ] \
    && ok "walk.resize reports FAIL when the window is the wrong size" \
    || bad "walk.resize did not fail on a 640x480 window asked to be 500x400"

# The renderer-sandbox case, both ways.
#
# It reads the whole machine's process table, which is right on a runner and
# wrong everywhere else, so it is asked only where $APP_PID says this run
# launched the app. Those are two different answers and both are checked here:
# the walks above ran without an APP_PID and must have skipped it, and a run
# that does have one, with something whose argv looks like a WebKitWebProcess
# and no bwrap over it, must go red.
#
# The decoy is `exec -a`, which sets a process's argv without running anything
# by that name -- there is no WebKitGTK on a machine that is running this file,
# and waiting for one would be a check that never runs.
[ "$(awk -F'\t' '$3 == "walk.renderer.sandboxed" { print $4 }' "$RESULTS")" = "SKIP" ] \
    && ok "the renderer-sandbox case skips when this run launched no app" \
    || bad "walk.renderer.sandboxed did not skip without an APP_PID"

echo 1 > "$STATE/idx"; echo 0 > "$STATE/seen"
mkxdotool 500x400
bash -c 'exec -a WebKitWebProcess sleep 30' >/dev/null 2>&1 &
DECOY=$!
# The decoy has to be visible before it can stand in for anything, and on MSYS
# it is not: `exec -a` renames the process for the kernel that has argv, and the
# `pgrep` there does not report it. A fixture that cannot plant its own subject
# is not measuring the verifier, so it says so rather than failing the run --
# the same shape as the grep -oP guard above, and the same reason. windows-launch
# found this by going red on it; the case itself is registered for gjs, kde and
# linux-engines and never runs there at all.
if pgrep -f WebKitWebProcess >/dev/null 2>&1; then
    SBX="$WORK/sandbox.tsv"
    PATH="$BIN:$PATH" NT_LANE=selftest NT_RESULTS="$SBX" NT_WAIT_TIMEOUT=5 \
        APP_PID=$$ bash "$ROOT/test/suite/verify-linux.sh" "$WORK/shots-sbx" > "$WORK/sbx.out" 2>&1
    [ "$(awk -F'\t' '$3 == "walk.renderer.sandboxed" { print $4 }' "$SBX")" = "FAIL" ] \
        && ok "walk.renderer.sandboxed reports FAIL for a web process with no bwrap over it" \
        || bad "walk.renderer.sandboxed did not fail on an unsandboxed web process"
else
    echo "  SKIP: this platform's pgrep cannot see an 'exec -a' decoy, so the"
    echo "        renderer-sandbox case has no subject to be planted for it"
fi
kill "$DECOY" 2>/dev/null || true
wait "$DECOY" 2>/dev/null || true
# The rest of the walk still has to be reported. A suite that stops at its first
# failure tells you one thing was wrong and nothing about what else was.
[ "$(awk -F'\t' '$3 == "walk.done" { print $4 }' "$BAD")" = "PASS" ] \
    && ok "one failed case does not stop the cases after it" \
    || bad "the walk stopped after the failure; later cases went unreported"

# A walk that *stops*, which is a different path from a case that fails.
#
# The check above is a comparator saying no: the title arrived, the window was
# the wrong size, and the walk carried on. This is a title that never arrives at
# all, and until nt_walk_stopped it was `nt_fail <id>; exit 1` -- no totals line,
# an exit status of 1 rather than the failure count test/run.sh adds up, and
# every case below the stop filing nothing at all.
#
# The last of those is what this is really for. An unreported case is a hole,
# and a hole is what --strict goes red on and what matrix.py cannot tell from a
# lane that never ran the suite -- so one genuine walk failure produced one FAIL
# and seven cells claiming the suite had not run, and the run that most needed
# reading was the one whose grid said the least.
#
# The first four titles and no more, with the instrument also reporting the
# wrong size. So the walk reaches STEP2, fails walk.resize on the geometry, and
# then waits out its timeout for a STEP3 that never comes -- two failures, one
# of them the stop.
#
# Two and not one on purpose. With a single failure the old shape's `exit 1`
# and the contract's "exit the failure count" are the same number, and a check
# that cannot tell them apart is not checking the contract. Here they are 1
# and 2.
cp "$STATE/titles" "$STATE/titles.full"
sed -n '1,4p' "$STATE/titles.full" > "$STATE/titles"
echo 1 > "$STATE/idx"; echo 0 > "$STATE/seen"
mkxdotool 640x480
STOP="$WORK/stop.tsv"
PATH="$BIN:$PATH" NT_LANE=selftest NT_RESULTS="$STOP" NT_WAIT_TIMEOUT=2 \
    bash "$ROOT/test/suite/verify-linux.sh" "$WORK/shots-stop" > "$WORK/stop.out" 2>&1
STOPRC=$?
cp "$STATE/titles.full" "$STATE/titles"

stopv() { awk -F'\t' -v c="$1" '$3 == c { print $4 }' "$STOP" 2>/dev/null; }

[ "$(stopv walk.move)" = "FAIL" ] \
    && ok "a walk that never reaches STEP3 fails the case it stopped on" \
    || bad "walk.move was '$(stopv walk.move)' on a walk that stopped there"

STOPSKIPPED=""
for c in walk.theme.readable walk.fonts.readable walk.done \
         walk.renderer.sandboxed; do
    [ "$(stopv "$c")" = "SKIP" ] || STOPSKIPPED="$STOPSKIPPED $c=$(stopv "$c" | tr -d '\n')"
done
[ -z "$STOPSKIPPED" ] \
    && ok "every case below the stop is skipped by name, not left unreported" \
    || bad "a stopped walk left these unskipped:$STOPSKIPPED"

# The two halves of the exit contract, which the bare `exit 1` had neither of.
grep -q '^report: totals ' "$WORK/stop.out" \
    && ok "a stopped walk still prints its totals line" \
    || bad "a stopped walk printed no totals line"
[ "$STOPRC" = "2" ] \
    && ok "a stopped walk exits its failure count, not 1" \
    || bad "a stopped walk exited $STOPRC, wanted 2 (one failure before the stop, and the stop)"

echo 1 > "$STATE/idx"; echo 0 > "$STATE/seen"
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
        # `walk` is not one of verify-std.sh's probes. It is the launcher's walk,
        # analysed by test/lib/walk.sh, and it shares this directory and this
        # naming because it is the same kind of thing: a real record off a real
        # lane, replayed with no display. Routed by name rather than by a second
        # directory, so that adding the next analyser's records is adding files.
        #
        # It cost a round to find out that it had to be routed at all: dropping
        # windows-launch.walk.tsv in here handed it to verify-std.sh as a probe
        # called "walk", which reported eight failures about a probe that does
        # not exist.
        if [ "$probe" = "walk" ]; then
            NT_LANE="${base%%.*}" NT_SUITE=verify-windows NT_RESULTS="$rrows" \
                bash "$ROOT/test/lib/walk.sh" "$rec" \
                > "$WORK/rec-$base.out" 2>&1
        else
            NT_LANE="${base%%.*}" NT_SUITE=verify-std NT_RESULTS="$rrows" \
                bash "$ROOT/test/suite/verify-std.sh" "$probe" "$WORK/shots-rec" "$rec" \
                > "$WORK/rec-$base.out" 2>&1
        fi
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
#
# $RESULTS is the walk fixture's rows, and the walk fixture only runs where there
# is a GNU grep -oP -- so on macOS this read a variable that was never set. Under
# `set -u` that kills the process substitution and not the loop around it, which
# is the worst of the three things it could have done: the loop read nothing, and
# a check that examined no ids at all reported PASS, in the same green as the
# lanes where it had examined thirty. The error went to stderr, one line above
# its own PASS, in a step nobody opens when the step is green.
#
# So it is asked only where its subject exists, and says so where it does not.
# The skip is the same shape as the one the fixture itself files above, and for
# the same reason: a check that cannot run has to be louder than a check that
# ran and found nothing.
if [ "$NT_HAVE_GREP_P" = 1 ]; then
    UNREG=""
    while IFS= read -r id; do
        grep -q "^$id	" "$ROOT/test/cases.tsv" || UNREG="$UNREG $id"
    done < <(awk -F'\t' '{print $3}' "$RESULTS" | sort -u)
    [ -z "$UNREG" ] && ok "every case id emitted is registered in cases.tsv" \
        || bad "emitted but not in cases.tsv:$UNREG"
else
    echo "  SKIP: the walk fixture did not run here, so no suite emitted an id"
    echo "        for this to hold against the registry"
fi

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
# A *record* beside the rows, which is not the same kind of file and used to be
# read as though it were. sheet.sh took any .tsv in a source directory for
# harness rows, and a record's six columns line up so that `inner` reads as a
# case id and `pos` as a verdict -- so the grid grew cases called `500x400` and
# `900x600`, each holding `54,40`, off the windows-launch load replicas. The
# three cases below must survive and nothing from this file may join them.
cp "$ROOT/test/lib/records/windows-launch.walk.tsv" "$SHEETSRC/a-record.tsv" 2>/dev/null || true
bash "$ROOT/test/report/sheet.sh" selftest "$WORK/sheet.html" "Logs=$SHEETSRC" >/dev/null 2>&1

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

# The grid's own two checks, against the sheet just built.
#
# matrix.py is the only tool that sees every lane at once, and until it grew
# --strict it reported what it saw to a step that returned 0 regardless. Both of
# the things it can now fail on had already happened and were caught by hand.
if command -v "$(nt_python)" >/dev/null 2>&1 && [ -f "$WORK/sheet.html" ]; then
    MREG="$WORK/registry.tsv"

    # Declared and reported: nothing wrong, and the tool must say so.
    {
        printf 'sheet.probe.a\ta control\tselftest\n'
        printf 'sheet.probe.b\ta control\tselftest\n'
        printf 'sheet.probe.c\ta control\tselftest\n'
    } > "$MREG"
    if "$(nt_python)" "$ROOT/test/report/matrix.py" --strict --registry "$MREG" \
        "$WORK/sheet.html" >/dev/null 2>&1; then
        ok "matrix.py --strict passes a lane that reported what it declared"
    else
        bad "matrix.py --strict failed a lane that reported exactly its cases"
    fi

    # An id in a sheet that the registry does not declare. This is the shape a
    # record read as rows takes: `500x400` reached the grid that way.
    printf 'sheet.probe.a\ta control\tselftest\n' > "$MREG"
    if "$(nt_python)" "$ROOT/test/report/matrix.py" --strict --registry "$MREG" \
        "$WORK/sheet.html" >/dev/null 2>&1; then
        bad "matrix.py --strict passed a sheet carrying undeclared case ids"
    else
        ok "matrix.py --strict fails on a case id cases.tsv does not declare"
    fi

    # A lane the registry expects rows from that reported none of them.
    printf 'nothing.reported.here\ta case no sheet carries\tselftest\n' > "$MREG"
    if "$(nt_python)" "$ROOT/test/report/matrix.py" --strict --registry "$MREG" \
        "$WORK/sheet.html" >/dev/null 2>&1; then
        bad "matrix.py --strict passed a lane that reported none of its cases"
    else
        ok "matrix.py --strict fails on a lane that went quiet"
    fi

    # And a case one lane reports and another does not, which is the same
    # failure at a finer grain and did not fail this tool until now: a case
    # missing on *some* of the lanes it applies to was drawn as a `-`, listed
    # under the grid, and exited 0. Three of those arrived in one push -- the
    # Darwin arm of netinstall/test/env.sh's toolkit block set two variables and
    # filed no rows -- and the only thing that noticed was a human diffing two
    # grids.
    #
    # Two lanes are needed to have a partial hole at all, so the second sheet is
    # the first with its lane renamed and one case cut out of the digest.
    sed -e 's/"lane":"selftest"/"lane":"selftest2"/' \
        -e 's/,{"id":"sheet.probe.c","v":"FAIL","suite":"[^"]*"}//' \
        "$WORK/sheet.html" > "$WORK/sheet2.html"
    {
        printf 'sheet.probe.a\ta control\tselftest selftest2\n'
        printf 'sheet.probe.b\ta control\tselftest selftest2\n'
        printf 'sheet.probe.c\tthe one the second lane drops\tselftest selftest2\n'
    } > "$MREG"
    if "$(nt_python)" "$ROOT/test/report/matrix.py" --strict --registry "$MREG" \
        "$WORK/sheet.html" "$WORK/sheet2.html" >/dev/null 2>&1; then
        bad "matrix.py --strict passed a case one lane reported and another did not"
    else
        ok "matrix.py --strict fails on a case missing from one of its lanes"
    fi
    # The control for it: the same two sheets, with the registry saying that the
    # third case applies to the lane that has it and not to the one that does
    # not. Nothing is then missing and nothing is undeclared, and it must pass --
    # or the check above would be firing on any two-lane grid rather than on the
    # hole. `sheet.probe.c` stays declared, because dropping it would trip the
    # undeclared-id check instead and prove the wrong thing.
    {
        printf 'sheet.probe.a\ta control\tselftest selftest2\n'
        printf 'sheet.probe.b\ta control\tselftest selftest2\n'
        printf 'sheet.probe.c\tdeclared only where it is reported\tselftest\n'
    } > "$MREG"
    if "$(nt_python)" "$ROOT/test/report/matrix.py" --strict --registry "$MREG" \
        "$WORK/sheet.html" "$WORK/sheet2.html" >/dev/null 2>&1; then
        ok "and passes two lanes that both reported everything declared"
    else
        bad "matrix.py --strict failed two lanes that reported all their cases"
    fi
else
    echo "  SKIP: no python3 or no sheet, so matrix.py --strict did not run"
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
# netinstall/test/*.sh is in this list and has to be. The reverse scan below has
# read that tree since splash.sh was converted, but this direction did not -- so
# a *misspelled* id in a netinstall suite was reported from the far side, as the
# correctly-spelled one being emitted nowhere, which names the registry rather
# than the typo. The `harness.sh` guard means the suites still speaking lib.sh's
# older words cost nothing here.
# ------------------------------------------- the suites that speak the harness

# Both scans below walk the same list, and until now each built it for itself:
# the same glob, the same two exclusions, the same `grep -q harness.sh`. It is
# built once, here, and that is not tidying.
#
# The second copy was written inside a command substitution, and bash 3.2 --
# which is what /bin/bash still is on macOS -- cannot parse a `case` in one. It
# takes the `)` that closes a case pattern for the `)` that closes the
# substitution, and reads everything after it as shell that was never meant to
# be: the run reported a syntax error, then `$1: unbound variable` from the awk
# below it, then exit 1. So the macos lane did not fail a check. It stopped
# having a selftest at all, forty passing lines in, on a line that is valid bash
# in the other nine lanes -- and the checks after it, which include every one
# that reads the case registry, have never run there.
#
# Out here there is no substitution for a `case` to end early, and there is no
# `case` either.
# test/*.ps1 is in the glob, and that is the whole of what this file needed in
# order to read the Windows suites. The six words are spelled the same in
# PowerShell -- `nt_pass attack.reported "..."` is the same sequence of
# whitespace-separated tokens in both languages -- so the awk below, the canary
# under it and the orphan scan further down all read a converted .ps1 without
# knowing that they are doing it. That is the reason harness.ps1 kept the six
# words rather than taking Verb-Noun names: a second vocabulary would have
# meant a second scan, and a second scan is a second thing that can quietly
# read nothing.
NT_SPEAKERS=""
for suite in "$ROOT"/test/suite/*.sh "$ROOT"/test/suite/*.ps1 \
        "$ROOT"/test/lib/*.sh "$ROOT"/test/lib/*.ps1 \
        "$ROOT"/test/build/*.sh "$ROOT"/test/build/*.ps1 \
        "$ROOT"/test/report/*.sh "$ROOT"/test/apparatus/*.sh \
        "$ROOT"/test/run.sh "$ROOT"/netinstall/test/*.sh; do
    [ -f "$suite" ] || continue
    base="$(basename "$suite")"
    # This file is excluded because it quotes all six words while checking them,
    # and harness.sh -- and now harness.ps1 -- because they define them rather
    # than calling them.
    [ "$base" = selftest.sh ] && continue
    [ "$base" = harness.sh ] && continue
    [ "$base" = harness.ps1 ] && continue
    # A suite speaks the harness by sourcing one of the two files that define
    # it -- or by sourcing something under test/lib/ that sources one of them.
    # The .sh spelling is `. ../lib/harness.sh` and the .ps1 spelling is
    # `. (Join-Path $PSScriptRoot "lib\harness.ps1")`, so the pattern matches
    # the filename and not the sourcing syntax, which the two do not share.
    #
    # The second half of that is the fix for a defect this file could not see.
    # The pattern was `harness\.(sh|ps1)` alone, so a suite reaching the
    # vocabulary through lib/title.sh or lib/live.sh -- which is how
    # decoflip.sh, fontflip.sh and themeflip.sh reach it -- named neither file
    # and was not a speaker. Their verdict calls went unread by both checks
    # below, and the canary said 1204 either way: a scan that stopped seeing
    # three files reports the same green as a tree with nothing wrong in it,
    # which is the exact shape this file has now been caught in three times.
    # verify-std.sh is a fourth, reaching it through lib/analyse.sh.
    #
    # Any path under test/lib/, and not a list of the libraries that carry the
    # harness. A wrong answer in one direction costs nothing -- a file scanned
    # for verdict calls it does not make is a file with no verdict calls -- and
    # a wrong answer in the other is the silence above. lib/display.sh brings
    # no harness and a suite that sources only it is read for nothing, which is
    # the right price.
    grep -qE 'harness\.(sh|ps1)|lib[/\\][A-Za-z0-9_-]+\.(sh|ps1)' "$suite" 2>/dev/null || continue
    NT_SPEAKERS="$NT_SPEAKERS $suite"
done

# ------------------------------------------------ every verdict call, read once

# The two checks below ask two questions about the same thing -- every verdict
# call in every suite that speaks the harness -- so the tree is read once into a
# table and both of them read the table.
#
# It is read in awk, and that is a portability fix and not a tidying. Both scans
# spelled the boundary in front of the verb `\b`, and `\b` is a GNU extension:
# POSIX ERE has no word boundary at all, and a grep whose ERE is the system's
# takes a backslash before an ordinary character as that character -- so the
# pattern went looking for a literal `bnt_pass`, matched nothing, and each check
# reported that nothing as a pass. This file knows better sixty lines up, where
# the orphan scan spells its own boundary `([^A-Za-z0-9.-]|$)` and says why.
# These two were written without it and nothing said so, because a scan that
# matches nothing and a tree with nothing wrong in it produce the same green.
#
# awk splits on whitespace, so the boundary is the field and there is none to
# spell. It reads the same 584 calls the greps read here, byte for byte, and it
# reads them on a platform where the greps may have been reading none.
CALLS="$WORK/calls.tsv"
: > "$CALLS"
for suite in $NT_SPEAKERS; do
    awk -v f="$(basename "$suite")" '
        # The same comment strip the greps did, and the same limitation: a `#`
        # inside a string takes the rest of the line with it. No verdict call in
        # the tree is written that way, and a scan that lexed the shell properly
        # would be a larger thing to trust than the one it replaced.
        { sub(/#.*/, "") }
        {
            for (i = 1; i < NF; i++) {
                verb = $i
                # The six words, the wrappers, and the two vocabularies built on
                # top of them: analyse.sh files through ctl_pass/ctl_fail/
                # ctl_skip and the walk verifiers through walk.sh nt_walk_*
                # comparators. A definition -- `ctl_pass() {` -- is a different
                # token and does not match.
                if (verb !~ /^(nt_pass|nt_fail|nt_skip|nt_eq|nt_match|ctl_pass|ctl_fail|ctl_skip|nt_walk_[a-z_]+|assert_[a-z_]+)$/) continue
                arg = $(i + 1)
                gsub(/"/, "", arg)
                if (arg ~ /^[a-z][a-z0-9]*(\.[a-z0-9.-]+)+$/) { print "id\t" f "\t" verb "\t" arg; continue }
                # An id handed through a variable. Five suites do it, and the
                # orphan scan above knows them by the assert_ prefix.
                if (arg ~ /^\$[A-Za-z_{0-9]/) continue
                # `command -v nt_pass >/dev/null` is a test for the function,
                # not a call of it. test/lib/walk.sh opens with one, because it
                # is sourced by three verifiers and refuses to load where the
                # harness has not been.
                if (arg == ">/dev/null") continue
                # Only the three verdict words are held to taking a literal id.
                # assert_*, ctl_* and nt_walk_* are handed one in a variable as
                # a matter of course, which is why they are read for ids above
                # and not judged for the want of one here.
                if (verb !~ /^nt_(pass|fail|skip|eq|match)$/) continue
                call = ""
                for (j = i; j <= NF && j < i + 7; j++) call = call (call == "" ? "" : " ") $j
                print "bad\t" f "\t" verb "\t" call
            }
        }
    ' "$suite" >> "$CALLS"
done

# ------------------------------------- the harness is loaded before it is used
#
# A suite that reads one of the harness's own variables above the line that
# sources it is a suite that dies on `set -u`, and it dies on the lane that runs
# it rather than here: `bash -n` is a syntax check and does not know that a name
# has no value yet, and most of these suites have no offline fixture at all.
#
# navrefuse.sh shipped exactly that. NT_STATUS_FILE was read at line 66 and the
# source sat at line 78, so the macos lane -- the only one that runs it --
# reported `NT_STATUS_FILE: unbound variable` and one failure, and it was the
# first thing anybody knew about it.
#
# Only the names harness.sh alone defines are looked for. nt_* *functions* are
# deliberately not, because netinstall/test/lib.sh defines its own and the
# documented order there is lib.sh first, so a call above the harness line is
# ordinary there and would make this scan cry wolf on sixteen files.
EARLY=""
for suite in $NT_SPEAKERS; do
    case "$suite" in *.ps1) continue ;; esac
    # The source *line* and not a mention of the filename. NT_SPEAKERS is built
    # by grepping for a filename, which a comment satisfies -- run.sh names
    # harness.sh in its own header and sources nothing -- so a file with no `.`
    # line is not a sourcing suite and this check does not apply to it.
    #
    # Any lib under test/lib/ counts as the line to be below, not harness.sh
    # alone. A suite that reaches the vocabulary through lib/title.sh gets
    # NT_STATUS_FILE from that source line, so that is the line its reads have
    # to come after -- and with only `harness.sh` named here, three such suites
    # had no source line the scan could find and were exempted from the check
    # rather than held to it.
    #
    # And the variable names carry a boundary, or NT_SUITE matches the
    # NT_SUITES_FILE that run.sh reads three lines in. That is the same defect
    # the orphan scan was fixed for, arrived at from the other side.
    n="$(awk '
        { line = $0; sub(/#.*/, "", line) }
        srcline == 0 && line ~ /^[[:space:]]*\.[[:space:]].*(harness\.sh|lib\/[A-Za-z0-9_-]+\.sh)/ { srcline = NR }
        use == 0 && line ~ /NT_(LANE|SUITE|RESULTS|STATUS_FILE|FAILURES|PASSES|SKIPS)([^A-Za-z0-9_]|$)/ { use = NR }
        END { if (srcline > 0 && use > 0 && use < srcline) print use; else print 0 }
    ' "$suite")"
    [ "$n" = 0 ] || EARLY="$EARLY $(basename "$suite"):$n"
done
[ -z "$EARLY" ] \
    && ok "every suite sources the harness above the first use of its variables" \
    || bad "a harness variable is read before the harness is sourced:$EARLY"

# The canary, and the reason either check below can be believed.
#
# Both of them report by finding nothing, so a scan that read no calls at all
# passes in exactly the same green as a tree with no defect in it. That is not a
# hypothetical: it is what `\b` did wherever the grep was not GNU's, and it is
# the second thing in this file caught examining an empty set and calling the
# result a pass. A scan gets to say how much it looked at.
#
# The three verdict words rather than a count, because a floor under 584 calls
# is a number somebody has to maintain and what actually separates a working
# scan from a broken one is that a broken one finds none of anything.
MUTE=""
for w in nt_pass nt_fail nt_skip; do
    n="$(awk -F'\t' -v w="$w" '$3 == w' "$CALLS" | wc -l | tr -d ' ')"
    [ "$n" -gt 0 ] || MUTE="$MUTE $w"
done
NCALLS="$(wc -l < "$CALLS" | tr -d ' ')"
NSPK="$(awk -F'\t' '{ print $2 }' "$CALLS" | sort -u | wc -l | tr -d ' ')"
[ -z "$MUTE" ] \
    && ok "the verdict-call scan reads the tree ($NCALLS calls in $NSPK suites)" \
    || bad "the verdict-call scan found no$MUTE anywhere, so the checks below prove nothing"

# Every literal id a suite hands a verdict word is in the registry.
#
# This walked the tree for itself until the table above existed, with its own
# copy of the glob, the exclusions and a `\b` of its own -- so it was the third
# scan in this section reading the same files three ways, and the third one that
# would have been reading none of them wherever `\b` is not a word boundary.
UNKNOWN=""
while IFS="$(printf '\t')" read -r _kind ufile _uverb uid; do
    [ -n "$uid" ] || continue
    grep -q "^$uid	" "$ROOT/test/cases.tsv" || UNKNOWN="$UNKNOWN $ufile:$uid"
done < "$CALLS"
UNKNOWN="$(printf '%s' "$UNKNOWN" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//;s/ *$//')"
[ -z "$UNKNOWN" ] && ok "every literal case id in every suite is registered" \
    || bad "emitted but not in cases.tsv: $UNKNOWN"

# And the other direction. A registry that accumulates ids nothing emits stops
# being able to tell a hole from a leftover, which is the one thing it is for.
# The suites, listed once. `grep -r --include` would do it in one line and is
# the sort of thing that turns out to mean something slightly different on the
# BSD grep macOS ships -- and the failure mode there is every id reported as an
# orphan, which reads as a catastrophe rather than as a portability note.
# netinstall/test/*.sh is in the list now, and it has to be: splash.sh speaks
# this vocabulary, and a registry that could not see the tree a suite lives in
# would call every id that suite emits an orphan -- or, worse, let an
# unregistered one through. The netinstall suites that still speak lib.sh's
# older words are simply files this scan finds no ids in, which costs nothing.
# test/*.ps1 for the same reason it is in the speaker list above: an id emitted
# only from PowerShell is emitted, and a scan that could not see the file it
# lives in would report it as registered-but-never-emitted -- which reads as a
# stale registry entry and would get the id deleted rather than the glob fixed.
NT_SUITES="$(ls "$ROOT"/test/suite/*.sh "$ROOT"/test/suite/*.ps1 \
    "$ROOT"/test/lib/*.sh "$ROOT"/test/lib/*.ps1 \
    "$ROOT"/test/build/*.sh "$ROOT"/test/build/*.ps1 \
    "$ROOT"/test/report/*.sh "$ROOT"/test/apparatus/*.sh "$ROOT"/test/run.sh \
    "$ROOT"/netinstall/test/*.sh \
    2>/dev/null | grep -v 'selftest\.sh$')"

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
    # nt_walk_* counts as emitting. test/lib/walk.sh names its ids as
    # arguments to the walk's own comparators -- `nt_walk_geometry
    # walk.resize ...` -- rather than to nt_pass directly, and a scan that
    # only knew the three verdict words would call every one of them an
    # orphan the moment the verifiers stop carrying the literals too.
    #
    # And assert_*, which is the same thing arrived at from the other side.
    # A suite whose assertions differ only in their fixture writes one
    # wrapper and hands it the id -- netinstall/test/verify.sh has five
    # rejections that differ in nothing else -- and inside that wrapper the
    # id is `$id`, which no literal scan can resolve. This is the shape and
    # not a file: the next converted suite that writes `assert_something` is
    # covered without this line being touched again. It is the same
    # allowance the `$stem\.\$` escape above makes for an id whose last
    # segment is built at runtime.
    #
    # $rid is followed by a boundary, and without it this scan reports a
    # false pass. The match was unanchored, so an id that is a *prefix* of
    # another was found by the longer one: registering envlen.trunc.keep255
    # beside envlen.trunc.keep255.control made the first one look emitted
    # whether anything emitted it or not. An orphan check that can be
    # satisfied by a different case is not checking the thing it is for.
    #
    # The boundary goes on that alternative only. The other one ends in a
    # literal `$` -- it is how an id whose last segment is built at runtime
    # is matched, `std.win.open-target.$v` -- and a boundary after it would
    # refuse the variable that has to follow.
    # One grep over every suite at once, and not one grep per suite.
    #
    # This asks only whether the id is emitted anywhere -- the file it was
    # found in was never used -- but the loop spawned a process per suite
    # per case to find that out. At 318 cases over 51 files that is sixteen
    # thousand greps, which is nothing here and most of five minutes under
    # the MSYS bash on windows-launch, where starting a process costs a
    # hundred times what it costs on Linux. Adding the .ps1 suites to the
    # list took it to twenty-five thousand and the step hit its five-minute
    # ceiling: the scan did not fail, it did not finish, and a check that
    # cannot finish is a check that is not run.
    #
    # `grep -q` over a file list stops at the first match exactly as the
    # loop's `break` did, so this is the same question asked once rather
    # than seventy-one times.
    if grep -qE "(nt_(pass|fail|skip|eq|match|walk_[a-z_]+)|ctl_(pass|fail|skip)|assert_[a-z_]+) \"?($rid([^A-Za-z0-9.-]|\$)|$stem\.\\\$)" $NT_SUITES 2>/dev/null; then
        :
    else
        ORPHAN="$ORPHAN $rid"
    fi
done < "$ROOT/test/cases.tsv"
[ -z "$ORPHAN" ] && ok "every registered case id is emitted by some suite" \
    || bad "in cases.tsv but emitted nowhere:$ORPHAN"

# The registry checked as a file, which nothing did. Both of these are silent
# failures rather than loud ones, which is why they need a check at all: the
# grid goes on rendering and says something confident and wrong.

# No id twice. test/report/matrix.py builds the registry as a dict keyed on the id, so
# a second row with the same id replaces the first -- its title and, the part
# that matters, its lane list. A case quietly expected on a different set of
# lanes turns real holes into `.` and back, and nothing anywhere says so.
DUPID="$(awk -F'\t' '!/^#/ && NF { print $1 }' "$ROOT/test/cases.tsv" | sort | uniq -d)"
[ -z "$DUPID" ] && ok "no case id is registered twice" \
    || bad "registered more than once in cases.tsv:$(echo $DUPID)"

# Every lane an applies-to names is a real job. A typo here does not fail, it
# disables: `applies()` matches no lane, every cell in that row reads `.`, and
# --strict has nothing to complain about because no lane was ever expected to
# report it. A case switched off by a misspelling looks exactly like a case that
# applies to nothing on purpose.
STRAYLANE=""
for l in $(awk -F'\t' '!/^#/ && NF { print $3 }' "$ROOT/test/cases.tsv" |
           tr ' ' '\n' | sort -u); do
    [ -n "$l" ] || continue
    [ "$l" = "*" ] && continue
    grep -qE "^  $l:\$" "$ROOT/.github/workflows/ci.yml" ||
        STRAYLANE="$STRAYLANE $l"
done
[ -z "$STRAYLANE" ] && ok "every lane a case applies to is a job in ci.yml" \
    || bad "named in a cases.tsv applies-to and not a job in ci.yml:$STRAYLANE"

# Every verdict call is handed an id and not a sentence.
#
# This is the shape a half-converted suite has, and it has happened: a call left
# as `nt_fail "the thing did not hold"` files its whole message as the name of a
# case, so the grid grows a row nobody registered and the case that should have
# been reported is a hole. Both halves of the registry scan above would catch it
# eventually -- one as an undeclared id, the other as an orphan -- but they name
# the registry, and this names the line.
#
# It is the check netinstall/test/fetchbound.sh wanted. Two of its calls sat
# inside a `case` arm rather than at the start of a line, a sweep for leftovers
# missed them, and with the local helpers deleted they became `ok: command not
# found` -- silently, because a case arm's status does not reach the exit code.
# A before-and-after diff of the prose caught that one; this catches the class.
BADARG="$(awk -F'\t' '$1 == "bad" { print " " $2 ":" substr($4, 1, 44) }' "$CALLS" |
    sort -u | tr -d '\n')"
[ -z "$BADARG" ] && ok "every verdict call is handed a case id, not a sentence" \
    || bad "a verdict call's first argument is not a case id:$BADARG"

# No case speaks only when it fails.
#
# A case whose every emission is a failure files nothing on a good run, so its
# cell is a hole -- and a hole was drawn as a `-` and exited green until
# matrix.py --strict started counting one. Two arrived that way two pushes ago
# and the grid caught them; this catches the shape at a desk instead.
#
# It is the single most common defect this whole conversion turned up. A dozen
# assertions across the netinstall tree spoke only on failure, which meant the
# row saying "the instrument exists" was filed on exactly the runs where nothing
# else could be. Given a passing voice, they say so on every run.
#
# A skip is not enough of a voice, and this line used to say it was: "a case
# that can only skip or fail is one that says why it could not answer, which is
# not silence." That is true of the skip and false of the case. navrefuse.respell
# could fail where the respelled build came out identical to the shipped one, and
# could be skipped by either gate above it, and on the run where the apparatus
# worked neither fired and it filed nothing. It read as a hole on macos, and
# matrix.py --strict found it a full round after this check had passed it.
#
# So what is required is a *passing* voice: an emitter that is not one of the
# four fail-or-skip words. A case with none cannot report a healthy run, and the
# healthy run is the one it will spend its life on. Measured before the rule was
# tightened: exactly one case in the tree had no passing voice, which is the one
# above, so this is not a rule the tree has to be bent to fit.
#
# The vocabulary above is the substantive change here, and it is the reason this
# is worth a second look so soon after writing it. The scan knew nt_pass,
# nt_fail, nt_skip and assert_* -- four of the six words and the wrapper prefix
# -- so 67 call sites were invisible to it: analyse.sh files 59 verdicts through
# ctl_* and the walk verifiers file 8 through walk.sh's comparators. A case that
# only ever ctl_fails is precisely the defect this check exists for, and the
# check could not see one. The orphan scan sixty lines up has known both
# vocabularies all along, for the same reason and in nearly the same words.
#
# With them in it still finds nothing, which is what makes the widening worth
# keeping: the shape is absent from those 67 sites as well, and that is a
# reading now rather than an assumption.
SILENT="$(awk -F'\t' '
    $1 != "id" { next }
    { seen[$4 "\t" $2] = 1
      if ($3 !~ /^(nt_fail|ctl_fail|nt_skip|ctl_skip)$/) voiced[$4] = 1 }
    END { for (k in seen) { split(k, a, "\t"); if (!(a[1] in voiced)) print a[2] ":" a[1] } }
' "$CALLS" | sort -u | tr '\n' ' ')"
[ -z "$SILENT" ] && ok "every case has a voice for the run where it holds" \
    || bad "these cases file nothing on a good run:$SILENT"

# ------------------------------------------------------------------- reap.sh

echo
echo "### reap.sh, against the caller it must not kill"

# reap.sh takes its pattern as an argument, so the pattern is in its own command
# line -- and in the command line of anything that passed it along. It already
# excluded itself, and its header predicted the rest: "the step that this
# replaces got away with the same call because its pattern was a literal in a
# script body, where no argv can see it -- which is luck, and stops being luck
# the moment anyone parameterises it."
#
# test/lib/step.sh parameterised it. `--app .../neutrinoattack.cmd` puts the pattern
# in step.sh's argv, `pgrep -f neutrinoattack` returned step.sh, and the suite
# was SIGTERMed and then SIGKILLed by the thing it had just called. It exited 137
# and the lane read that as 137 failures.
if command -v pgrep >/dev/null 2>&1 && command -v ps >/dev/null 2>&1; then
    REAPCALLER="$WORK/reap-caller.sh"
    # reap.sh's path arrives in the environment and not in argv, which matters:
    # the older exclusion dropped anything whose command line mentioned
    # `reap.sh`, so a caller that named the script as an argument was filtered by
    # accident and this check passed against the very version it exists to
    # catch. The caller's argv must carry the pattern and nothing else.
    cat > "$REAPCALLER" <<'CALLEREOF'
#!/bin/bash
bash "$NT_REAP_SH" nt-selftest-no-such-process >/dev/null 2>&1
echo SURVIVED
CALLEREOF
    out="$(NT_REAP_SH="$ROOT/test/lib/reap.sh" bash "$REAPCALLER" \
        --app /tmp/nt-selftest-no-such-process.cmd 2>/dev/null)"
    if [ "$out" = "SURVIVED" ]; then
        ok "reap.sh does not kill the process that called it"
    else
        bad "reap.sh killed its own caller (argv carried the pattern)"
    fi
else
    echo "  SKIP: no pgrep/ps here, so reap.sh's ancestry check did not run"
fi

# ------------------------------------------------------------------- walk.sh

echo
echo "### walk.sh, against a walk that should not pass"

# The replay above proves walk.sh can say PASS. This proves it can say FAIL,
# which is the half that a deleted assertion would still satisfy. Same argument
# as the 640x480 stub walk in the verify-linux.sh section above.
WALKREC="$ROOT/test/lib/records/windows-launch.walk.tsv"
if [ -f "$WALKREC" ]; then
    # A window that never resized, and a move that never happened.
    sed 's/500x400/900x600/' "$WALKREC" | grep -v '	STEP3	' > "$WORK/walk-bad.tsv"
    WBROWS="$WORK/walk-bad-rows.tsv"
    NT_LANE=selftest NT_SUITE=verify-windows NT_RESULTS="$WBROWS" \
        bash "$ROOT/test/lib/walk.sh" "$WORK/walk-bad.tsv" > "$WORK/walk-bad.out" 2>&1
    wbrc=$?
    [ "$wbrc" = 2 ] && ok "a walk that did not resize or move fails twice" \
        || bad "a broken walk exited $wbrc, wanted 2"
    # Column three is the case id and four the verdict -- the row is
    # lane/suite/id/verdict/detail, which an anchored grep gets wrong.
    nt_verdict() { awk -F'\t' -v id="$1" '$3 == id { print $4; exit }' "$WBROWS"; }
    [ "$(nt_verdict walk.resize)" = FAIL ] &&
        ok "walk.resize failed on a window that stayed 900x600" ||
        bad "walk.resize did not fail on a window that never resized"
    [ "$(nt_verdict walk.move)" = FAIL ] &&
        ok "walk.move failed on a state that never arrived" ||
        bad "walk.move did not fail on a missing STEP3"
    # And the cases behind the two failures still reported. A replay that
    # stopped at the first red would take every later reading with it, which is
    # the defect the live verifiers have `exit 1` for and this one must not.
    [ "$(nt_verdict walk.done)" = PASS ] &&
        ok "the cases behind a failure still reported" ||
        bad "walk.sh stopped at the first failing case"

    # Sourced, it must not replay. It sees the caller's positional parameters,
    # and verify-linux.sh is called with a screenshots directory -- which this
    # file caught being read as a record path the first time walk.sh was written.
    ( set -- "$WORK/not-a-record-just-a-dir"
      # shellcheck source=/dev/null
      . "$ROOT/test/lib/walk.sh"
      command -v nt_walk_title >/dev/null 2>&1 || exit 3
    ) > "$WORK/walk-src.out" 2>&1
    srrc=$?
    if [ "$srrc" = 0 ] && ! grep -q 'no record at' "$WORK/walk-src.out"; then
        ok "sourcing walk.sh defines the comparators and replays nothing"
    else
        bad "sourcing walk.sh with a caller's arguments tried to replay them"
    fi
else
    echo "  SKIP: no windows-launch.walk record to replay"
fi

# --------------------------------------------------------------------- run.sh

echo
echo "### run.sh, and the manifest it reads"

# The manifest, checked without running anything on it. A typo in a lane name or
# an artifact name is a suite that silently does not run, and the run it does not
# happen in is a green one -- so this is the half worth catching at a desk.

RUNSH="$ROOT/test/run.sh"
SUITES_TSV="$ROOT/test/suites.tsv"
LANES_TSV="$ROOT/test/lanes.tsv"
BUILDS_TSV="$ROOT/test/builds.tsv"

# Column shape. A row with the wrong number of columns puts a command in the
# setup column, where it is reported as an unknown directive -- a sentence about
# a directive, for a defect about a tab.
BADCOLS="$(awk -F'\t' '!/^#/ && NF { if (NF < 3 || NF > 4) print FILENAME ":" FNR }' \
    "$SUITES_TSV")"
[ -z "$BADCOLS" ] && ok "every suites.tsv row has three or four columns" \
    || bad "suites.tsv rows with the wrong column count:$(echo $BADCOLS)"

BADCOLS="$(awk -F'\t' '!/^#/ && NF && NF != 4 { print FILENAME ":" FNR }' "$BUILDS_TSV")"
[ -z "$BADCOLS" ] && ok "every builds.tsv row has four columns" \
    || bad "builds.tsv rows with the wrong column count:$(echo $BADCOLS)"

# Every artifact a suite asks for is declared, and every declared artifact is
# asked for. Both directions, for the reason the registry scan below runs both:
# an artifact nobody builds is a row nobody reads, and an artifact nobody
# declared is a lane that fails at the point it was supposed to start measuring.
APPNAMES="$(awk -F'\t' '!/^#/ && NF { print $1 }' "$BUILDS_TSV")"
# awk and not `sed -n 's/^\(app\|build\)=//p'`: `\|` is GNU's alternation and
# BSD sed reads it as a literal, so on macOS that expression matched nothing and
# this list came back empty -- which made the next check report all five
# artifacts as unused. The first thing the macos lane caught.
WANTED_APPS="$(awk -F'\t' '!/^#/ && NF { print $3 }' "$SUITES_TSV" |
    tr ' ' '\n' |
    awk '/^(app|build)=/ {
        sub(/^(app|build)=/, "")
        # `<slot>:<build>` -- the slot names the artifact, and the build is
        # what this scan asks about.
        sub(/^[^:]*:/, "")
        print
    }' | sort -u)"

# And the artifacts named by `run.sh --build` in a workflow, which is how a lane
# whose suites are still pwsh asks for one. Those rows are read by the same
# table and are no less declared for the step that runs them not being a
# manifest row yet -- without this, every windows artifact reads as an orphan
# and the check that is supposed to find a leftover finds eleven of them.
# `--build <slot>=<build> ...`; this wants the build half of each pair.
#
# It filtered on a `neutrino` prefix until the builds were renamed, and that is
# a shape worth not repeating: a filter naming the thing it filters for matches
# nothing the day the naming changes, and a scan that matches nothing reports
# the same green as a tree with nothing wrong in it.
WANTED_APPS="$WANTED_APPS $(sed -n 's/.*run\.sh --build //p' \
    "$ROOT"/.github/workflows/*.yml | tr ' ' '\n' |
    awk -F= 'NF == 2 { print $2 } NF == 1 && $1 != "" { print $1 }' | sort -u)"

MISSING=""
for a in $WANTED_APPS; do
    case " $(echo $APPNAMES) " in *" $a "*) ;; *) MISSING="$MISSING $a" ;; esac
done
[ -z "$MISSING" ] && ok "every build a suite names is declared in builds.tsv" \
    || bad "named by a suite and not in builds.tsv:$MISSING"

UNUSED=""
for a in $APPNAMES; do
    case " $(echo $WANTED_APPS) " in *" $a "*) ;; *) UNUSED="$UNUSED $a" ;; esac
done
[ -z "$UNUSED" ] && ok "every build in builds.tsv is named by some suite" \
    || bad "in builds.tsv and named by nothing:$UNUSED"

# The sources exist. mkapp.sh would say so too, but it would say it on a runner
# eight minutes into a lane rather than here.
MISSING=""
while IFS="$(printf '\t')" read -r name builder source flags; do
    case "$name" in \#*|"") continue ;; esac
    [ "$builder" = "mkapp" ] || continue
    [ -f "$ROOT/test/probe/$source" ] || MISSING="$MISSING $source"
done < "$BUILDS_TSV"
[ -z "$MISSING" ] && ok "every mkapp source in builds.tsv is on disk" \
    || bad "named in builds.tsv and not on disk:$MISSING"

# Every lane in the manifest is a job in the workflow. A lane key that is not a
# job is rows nobody will ever run, and it looks identical to rows that ran green.
LANES="$(awk -F'\t' '!/^#/ && NF { sub(/:.*/, "", $1); print $1 }' "$LANES_TSV" | sort -u)"
LANEKEYS="$(awk -F'\t' '!/^#/ && NF { print $1 }' "$LANES_TSV" | tr '\n' ' ')"
NT_SEEN=""
JOBS="$(sed -n 's/^  \([a-z0-9-]*\):$/\1/p' "$ROOT/.github/workflows/ci.yml")"
STRAY=""
for l in $LANES; do
    case " $(echo $JOBS) " in *" $l "*) ;; *) STRAY="$STRAY $l" ;; esac
done
[ -z "$STRAY" ] && ok "every lane in lanes.tsv is a job in ci.yml" \
    || bad "in lanes.tsv and not a job in ci.yml:$STRAY"

# Every lane a suite names is a lane, and no lane is claimed twice for one
# suite. This is what makes the lists disjoint rather than ordered: with two
# rows for `walk` there is no precedence to remember, because at most one of
# them can apply -- and a typo in a lane list is rows nobody runs, which reads
# exactly like rows that ran green.
LANEDUP=""; LANESTRAY=""
while IFS="$(printf '\t')" read -r nt_suite nt_lanes _rest; do
    case "$nt_suite" in \#*|"") continue ;; esac
    [ "$nt_lanes" = "*" ] && nt_lanes="$LANEKEYS"
    for nt_l in $nt_lanes; do
        case " $LANEKEYS " in *" $nt_l "*) ;; *) LANESTRAY="$LANESTRAY $nt_suite:$nt_l" ;; esac
        case " $NT_SEEN " in
            *" $nt_suite/$nt_l "*) LANEDUP="$LANEDUP $nt_suite/$nt_l" ;;
            *) NT_SEEN="$NT_SEEN $nt_suite/$nt_l" ;;
        esac
    done
done < "$SUITES_TSV"
[ -z "$LANESTRAY" ] && ok "every lane a suite names is a lane in lanes.tsv" \
    || bad "named by a suite and not a lane:$LANESTRAY"
[ -z "$LANEDUP" ] && ok "no suite claims one lane twice" \
    || bad "claimed by two rows of the same suite:$LANEDUP"

# A file that walks up to the repo root walks up the right number of times.
#
# This is the room move's other defect, and the one a path check cannot see:
# decoflip.ps1 reached the root with two Split-Path steps, which was right at
# test/decoflip.ps1 and one short at test/suite/decoflip.ps1. Nothing resolves
# a path that is only wrong at runtime, and `$root` there is used to build three
# more -- so the file found neither its artifact nor the verifier nor the
# differential, and said so three different ways.
#
# The invariant is arithmetic and needs no filesystem: a file that means to
# reach the repo root has to climb exactly as far as it sits below it. So the
# depth is counted from the path and the climb from the expression, and they
# have to agree.
#
# Only expressions that say they are reaching the root -- ROOT= in shell and
# $root = in PowerShell. A file walking up to something else is doing something
# this check has no opinion about, which is why serve-target.sh's $DOCS and
# verify-nav.ps1's $docs are not in it: those reach *down* into another room,
# and what makes them right is the room's name and not a count.
DEPTH=""
for f in "$ROOT"/test/*/*.sh "$ROOT"/test/*/*.ps1; do
    [ -f "$f" ] || continue
    rel="${f#$ROOT/}"
    # Directories between the repo root and the file: test/suite/x.sh is 2.
    want="$(printf '%s' "$rel" | awk -F/ '{ print NF - 1 }')"
    # Shell: ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
    got="$(sed -n 's/^ROOT="\$(cd "\$(dirname "\$0")\([^"]*\)".*/\1/p' "$f" |
        head -1 | grep -o '\.\.' | wc -l | tr -d ' ')"
    case "$rel" in
        *.sh) grep -q '^ROOT="\$(cd "\$(dirname "\$0")' "$f" || continue ;;
        *.ps1)
            grep -q '^\$root = Split-Path' "$f" || continue
            got="$(grep -m1 '^\$root = Split-Path' "$f" |
                grep -o 'Split-Path' | wc -l | tr -d ' ')" ;;
    esac
    [ "$got" = "$want" ] || DEPTH="$DEPTH $(basename "$f"):climbs=$got,depth=$want"
done
[ -z "$DEPTH" ] && ok "every file that walks up to the repo root climbs as far as it sits" \
    || bad "a root walk does not match the file's depth:$DEPTH"

# Every test/ file a workflow names is on disk, in both spellings.
#
# This check exists because the room move shipped without it and the Windows
# lane found the gap. Every `test/x.ps1` in ci.yml is written with backslashes
# -- `& .\test\verify-std.ps1` -- and a rewrite that matched forward slashes
# left all twenty-five of them pointing at files that had moved. Eight steps
# failed with "is not recognized as a name of a cmdlet, function, script file",
# eighteen minutes into a lane, on a path a one-second check can resolve.
#
# Both separators, because the two lanes that spell it with a backslash are the
# two nothing else in this file reads.
#
# Only extensions that name a *source*. The `.cmd` artifacts and the app
# directories beside them are build outputs: .gitignore lists them, they are
# absent on a clean checkout, and a check that demanded them would fail
# everywhere except on a runner that had already built them.
MISSINGPATH=""
for wf in "$ROOT"/.github/workflows/*.yml; do
    for p in $(grep -ohE 'test[/\\][A-Za-z0-9._/\\-]+\.(sh|ps1|py|js|tsv|qml|containerfile)' "$wf" |
            tr '\\' '/' | sort -u); do
        [ -e "$ROOT/$p" ] || MISSINGPATH="$MISSINGPATH $(basename "$wf"):$p"
    done
done
[ -z "$MISSINGPATH" ] && ok "every test/ file a workflow names is on disk" \
    || bad "named in a workflow and not on disk:$MISSINGPATH"

# No suite is run twice: once from the manifest and once by a hand-written step.
# This is what makes a half-migrated lane safe, and it is the check that stops
# the migration quietly double-running a suite for a whole round.
# Over the full lane keys and not $LANES, which has the phase stripped off.
# `run.sh --list linux-engines` returns nothing -- its rows are filed under
# linux-engines:cjs and :py -- so iterating the stripped names made this check
# vacuous for the one lane that runs its list twice, which is the lane most able
# to run a suite twice by accident.
DOUBLED=""
for lk in $(awk -F'\t' '!/^#/ && NF { print $1 }' "$LANES_TSV"); do
    l="${lk%%:*}"
    for sname in $(bash "$RUNSH" --list "$lk" 2>/dev/null); do
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

# And the mirror of it, which nothing checked: a row that exists here and is
# named by no step never runs at all.
#
# The check above makes a half-migrated lane safe in one direction -- a suite
# cannot be run twice -- and the migration relies on the other direction being
# temporary. A row lands in suites.tsv first and a step is pointed at it after,
# so between those two commits the row is dormant on purpose. What nothing
# noticed is a migration that stops there: the row reads like a suite the lane
# runs, `run.sh --list` names it, and no runner ever reaches it. That is a suite
# quietly deleted by a file that looks like it declares one.
DORMANT=""
for lk in $(awk -F'\t' '!/^#/ && NF { print $1 }' "$LANES_TSV"); do
    l="${lk%%:*}"
    for sname in $(bash "$RUNSH" --list "$lk" 2>/dev/null); do
        awk -v lane="$l" '
            /^  [a-z0-9-]+:$/ { j = $1; sub(/:$/, "", j) }
            j == lane && /test\/run\.sh/ { print }
        ' "$ROOT/.github/workflows/ci.yml" | grep -qE "[ ]$sname([ ]|$)" ||
            DORMANT="$DORMANT $lk/$sname"
    done
done
[ -z "$DORMANT" ] && ok "every suites.tsv row is named by a step in its lane" \
    || bad "declared in suites.tsv and named by no step:$DORMANT"

# The apparatus a suite needs is brought up by that suite, not by the step that
# calls it. test/apparatus/stall.py and test/apparatus/serve-target.sh are the case this is written
# about: three lanes each spelled the same twelve lines to start them, launch
# the app between them and tear them down afterwards, and the three copies were
# not identical -- macos cleared the status file and cat'd the app's log, the
# other two did neither. Nothing in the YAML said whether that was deliberate.
#
# The order is the whole content of those twelve lines: the target must answer
# before the app launches, or the navigation fails on its own and every driver
# reports `held` whether it has a guard or not. An ordering constraint pasted
# into three jobs is an ordering constraint nobody is checking, so it lives in
# test/suite/early.sh and test/suite/navrefuse.sh, which are the two files that need it.
#
# ERE and not `grep -e a \| b`: BSD grep reads GNU's BRE alternation as two
# literal characters, and this file runs on the macos lane.
# awk and not grep: the match has to be filtered to lines that are not YAML
# comments, and after `grep -n` prepends `file:line:` a `grep -v '^ *#'` is
# looking at the path. One pass, and the comment test is against the line's own
# text. ERE and not `\|` anywhere near this, either -- BSD grep reads GNU's BRE
# alternation as two literal characters, and this file runs on the macos lane.
HANDLAID="$(awk '
    /^[ \t]*#/ { next }
    /test\/stall\.py/ || /test\/serve-target\.sh/ { print FILENAME ":" FNR }
' "$ROOT"/.github/workflows/*.yml)"
[ -z "$HANDLAID" ] && ok "no workflow step brings up the stall socket or the navigation target by hand" \
    || bad "the early-navigation apparatus is spelled in a workflow step at:$(echo $HANDLAID)"

# Every lane's ceiling block sits above the lane it is about.
#
# Seven jobs carry the same five-line comment, each opening with what that lane
# was measured at, and it is the file's account of why the number below it is
# the number. One of them had drifted several steps down the file and was
# sitting inside the *previous* job's step list -- so kde's block, naming a
# netinstall step that may take 35 minutes, appeared to annotate kde-live, which
# runs test/apparatus/qtkde.sh alone and has no netinstall step at all. A reader following
# it would have been reading about the wrong lane, and kde-live, whose ceilings
# it looked like it explained, had none of its own.
#
# A comment attached to the wrong thing is worse than no comment, and it is
# exactly what this project keeps its memory in. So: past the block, the next
# line that is not a comment must be a job key.
STRAYCEIL="$(awk '
    /this lane took/ { want = 1; at = FNR; next }
    want && /^[ \t]*#/ { next }
    want { if ($0 !~ /^  [a-z0-9-]+:$/) print at; want = 0 }
' "$ROOT/.github/workflows/ci.yml")"
[ -z "$STRAYCEIL" ] && ok "every lane ceiling comment sits above the job it names" \
    || bad "a ceiling comment is not above a job key, at ci.yml:$(echo $STRAYCEIL)"

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

# No pattern in the tree uses a GNU-only regex operator.
#
# Two of them, and they fail the same way. `\b` is a word boundary POSIX ERE does
# not have; `\|` is alternation POSIX BRE does not have. A grep or sed whose
# regex is the system's reads the backslash before an ordinary character as that
# character, so both patterns go looking for a literal `b` or `|` and match
# nothing -- and matching nothing is indistinguishable from finding nothing
# wrong. Every failure of this is silent, and every one is in the direction of a
# pass.
#
# `\|` was found and named on this branch already: a manifest check spelled
# `sed -n 's/^\(app\|build\)=//p'`, the macos lane matched nothing, and the note
# on that commit is the one worth keeping -- "an empty list has nothing to fail
# on". Two more were sitting in the tree. test/suite/assemble.sh asked whether any CSS
# comment survived the strip with `grep -c 'a\|b\|c'` and asserted the answer was
# 0, which is what a pattern that cannot match returns for free; that file runs
# on GNU, MSYS and BSD deliberately. netinstall/test/phases.sh built its marks
# string the same way, on two BSD lanes, for cases that all skip today.
#
# `\b` was three patterns in this file and one in test/build/parse.sh, which runs on
# every artifact on every lane and would have been telling macos the launcher
# declares no name jsc.exe reserves without reading a line of it.
#
# What the tree uses instead is a character class for a boundary --
# `([^A-Za-z0-9.-]|$)` in the orphan scan, `([^A-Za-z0-9_$]|$)` in parse.sh --
# and `-E` for alternation, which is one dialect on every userland.
#
# Comments are stripped first: this file discusses both at length and would
# otherwise be its own worst offender. The `\|` half only looks at a grep or sed
# that was not given -E, because in an ERE a backslashed pipe is a literal pipe
# and a legitimate thing to want.
GNUISM=""
for f in "$ROOT"/test/suite/*.sh "$ROOT"/test/lib/*.sh "$ROOT"/test/build/*.sh \
        "$ROOT"/test/report/*.sh "$ROOT"/test/apparatus/*.sh "$ROOT"/test/run.sh \
        "$ROOT"/netinstall/test/*.sh; do
    [ -f "$f" ] || continue
    stripped="$(sed 's/#.*//' "$f")"
    hits="$(printf '%s\n' "$stripped" | grep -nE '(grep|sed|awk)[^|]*\\b' || true)"
    alt="$(printf '%s\n' "$stripped" | grep -nE '(grep|sed)' |
        grep -F '\|' | grep -vE '(grep|sed)[a-zA-Z]* +-[a-zA-Z]*E' || true)"
    for h in "$hits" "$alt"; do
        [ -n "$h" ] || continue
        GNUISM="$GNUISM $(basename "$f"):$(printf '%s' "$h" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')"
    done
done
[ -z "$GNUISM" ] && ok "no pattern in the tree uses a GNU-only regex operator" \
    || bad "a GNU-only \\b or \\| is in a pattern at:$GNUISM"

# Every suite in the manifest can carry a count out.
#
# run.sh adds a lane up by summing what its suites exit with, and says so at
# length: that contract is why it does not have to parse a log, and harness.sh's
# nt_finish exists to keep it. Five suites did not. appdir.sh ended `exit 0`
# behind a guard, assemble.sh `exit 1`, loaders.sh `exit $((FAILURES > 0))`, and
# verify-attack.sh and navrefuse.sh simply ended on `[ "$FAILURES" -eq 0 ]` --
# every one of them a deliberate spelling of "did anything break", and every one
# older than the runner that started summing them. assemble.sh makes a hundred
# and eleven assertions and could report at most one.
#
# It is not a failure anybody would see. The lane still goes red, because one is
# not zero; the number in the summary is just wrong, and it is the number a
# reader uses to judge how bad a run is.
#
# The rule is about the last statement and not about the whole file, because
# that is what the shell exits with. `nt_finish` passes. So does an exit of
# something that was counted -- `exit "$FAILURES"`, and the two suites that sum
# their halves, `exit $((HALF_FAILURES + DIFF_FAILURES))` and
# `exit $((DIFF_RC + LIVE_RC))`. A constant does not, and neither does a
# comparison, which is the form that hides best: `$((FAILURES > 0))` mentions
# the counter and throws it away.
SATURATE=""
for f in $(awk -F'\t' '!/^#/ && NF>=4 { print $4 }' "$SUITES_TSV" |
           grep -oE 'test/[a-z-]+\.sh' | sort -u); do
    [ -f "$ROOT/$f" ] || continue
    # The last line that is not blank and not a comment, which is the statement
    # the shell's exit status comes from.
    last="$(sed 's/#.*//' "$ROOT/$f" | awk 'NF { keep = $0 } END { print keep }' |
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ "$last" = "nt_finish" ] && continue
    if printf '%s' "$last" | grep -qE '^exit "?\$' &&
       ! printf '%s' "$last" | grep -qE '(-eq|-ne|-gt|-lt|>|<|!=)'; then
        continue
    fi
    SATURATE="$SATURATE $f:$last"
done
[ -z "$SATURATE" ] && ok "every suite in the manifest exits its failure count" \
    || bad "a suite's last statement cannot carry a count:$SATURATE"

# The arithmetic, against a fixture manifest. No display, no app, no artifact:
# what is under test is that a lane adds up and that a suite cannot hide.
FIXBIN="$WORK/runbin"; mkdir -p "$FIXBIN"
for n in 0 2 3; do
    printf '#!/bin/sh\nexit %s\n' "$n" > "$FIXBIN/ntexit$n"
    chmod +x "$FIXBIN/ntexit$n"
done
FIXTSV="$WORK/fixture-suites.tsv"
{
    printf 'green\tfixture\t-\tntexit0\n'
    printf 'three\tfixture\t-\tntexit3\n'
    printf 'two\tfixture\t-\tntexit2\n'
} > "$FIXTSV"

# The lane the fixtures run on. It was the `*` row in each of them; with a table
# per thing it is a table, and NT_LANES_FILE is the third of the three the
# runner reads -- which is also the first time any test has exercised one of
# those overrides.
FIXLANES="$WORK/fixture-lanes.tsv"
printf 'fixture\ttimeout=20\n' > "$FIXLANES"
LEASHLANES="$WORK/fixture-leash-lanes.tsv"
printf 'fixture\ttimeout=2\n' > "$LEASHLANES"

FIXOUT="$(PATH="$FIXBIN:$PATH" NT_SUITES_FILE="$FIXTSV" NT_LANES_FILE="$FIXLANES" bash "$RUNSH" fixture 2>&1)"
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
    printf 'wedged\tfixture\t-\tsleep 30\n'
    printf 'after\tfixture\t-\tntexit0\n'
} > "$LEASHTSV"
LEASHOUT="$(PATH="$FIXBIN:$PATH" NT_SUITES_FILE="$LEASHTSV" NT_LANES_FILE="$LEASHLANES" bash "$RUNSH" fixture 2>&1)"
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
printf 'oops\tfixture\tnosuchdirective\tntexit0\n' > "$BADTSV"
BADOUT="$(PATH="$FIXBIN:$PATH" NT_SUITES_FILE="$BADTSV" NT_LANES_FILE="$FIXLANES" bash "$RUNSH" fixture 2>&1)"
printf '%s' "$BADOUT" | grep -q "unknown setup directive 'nosuchdirective'" &&
    ok "an unknown setup directive is refused by name" ||
    bad "an unknown setup directive was not refused"

# The selection, which is what keeps a half-migrated lane from double-running.
SELOUT="$(PATH="$FIXBIN:$PATH" NT_SUITES_FILE="$FIXTSV" NT_LANES_FILE="$FIXLANES" bash "$RUNSH" fixture two 2>&1)"
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

# The row's name is what the harness files under.
#
# harness.sh derives $NT_SUITE from `basename "${0%.sh}"` when nothing sets it,
# which names a suite after the script that implements it. That is one name for
# four rows wherever a script serves more than one: stddoc, stdwin, stdtheme and
# stdfont are all test/suite/verify-std.sh, and every row they filed said `verify-std`.
# run.sh exports the manifest's name over it, and this is what says so.
#
# The stub is deliberately not a .sh, so the two answers cannot be confused: left
# to itself the harness would call this suite `ntspeak`.
NAMETSV="$WORK/fixture-name.tsv"
NAMEDIR="$WORK/nameresults"
mkdir -p "$NAMEDIR"
cat > "$FIXBIN/ntspeak" <<NTSPEAK
#!/bin/bash
. "$ROOT/test/lib/harness.sh"
nt_pass fixture.named "a row that says which row asked for it"
NTSPEAK
chmod +x "$FIXBIN/ntspeak"
printf 'the-row-name\tfixture\ttimeout=20\tntspeak\n' > "$NAMETSV"
PATH="$FIXBIN:$PATH" NT_SUITES_FILE="$NAMETSV" NT_LANES_FILE="$FIXLANES" NT_RESULTS_DIR="$NAMEDIR" \
    bash "$RUNSH" fixture >/dev/null 2>&1
[ -f "$NAMEDIR/the-row-name.tsv" ] \
    && ok "the harness files a row under the manifest's name for it" \
    || bad "a row filed as $(ls "$NAMEDIR" 2>/dev/null | tr '\n' ' ')rather than the-row-name.tsv"
# The filename and the column are set from the same variable, but they are read
# by different things -- sheet.sh globs the directory, and its digest carries the
# column -- so a change that moved one and not the other would be found here.
NAMECOL="$(awk -F'\t' '{ print $2 }' "$NAMEDIR/the-row-name.tsv" 2>/dev/null | sort -u | tr '\n' ' ')"
[ "$NAMECOL" = "the-row-name " ] \
    && ok "and names it in the row's own suite column" \
    || bad "the suite column says '$NAMECOL' and not the-row-name"

# ------------------------------------------------- the workflow lint, which ran nowhere

echo
echo "### every artifact a lane runs comes out of the registry"

# Two rules, and both of them are things this tree did until now.
#
# The first: a workflow may not build an artifact. test/builds.tsv is the table of
# what exists and test/run.sh is what builds it, and the whole reason for both is
# that eighty-four mkapp.sh lines across ten lanes were a test framework kept in
# YAML. Eleven artifacts were still built by hand here, none of them passed
# through parse.sh, and nothing could see that they were the exception.
#
# The second: nothing rewrites an assembled artifact. neutrino/assemble.sh
# performs no substitution -- that is the property build.sh was deleted for --
# and a `sed -i` over a built .cmd puts it back one lane at a time, with a
# read-back after it standing in for the failure path a substitution does not
# have. The windows-launch lane did exactly this to two constants, and the
# artifact it measured was the one artifact in the tree that no single
# assemble.sh run had produced.
#
# netinstall/ is not scanned for either. That suite fetches, verifies and slots
# opaque bytes: its payloads are written by hand on purpose, several of them are
# deliberately malformed, and one appends to a .cmd to make a second version.
NT_WF="$(ls "$ROOT"/.github/workflows/*.yml 2>/dev/null)"
BUILDERS=""
for wf in $NT_WF; do
    # The builders by their paths, and not by their basenames: `assemble.sh` is
    # also the name of the suite that asserts the assembler, which this lane
    # runs on purpose and which is not a build of anything a lane then runs.
    grep -nE 'test/build/(mkapp|demoapp)\.sh|neutrino/assemble\.sh' "$wf" \
        | grep -v '^[0-9]*: *#' \
        | while IFS= read -r hit; do echo "$(basename "$wf"):${hit%%:*}"; done
done > "$WORK/wfbuild.txt"
BUILDERS="$(tr '\n' ' ' < "$WORK/wfbuild.txt" | sed 's/ *$//')"
[ -z "$BUILDERS" ] \
    && ok "no workflow builds an artifact for itself" \
    || bad "a workflow calls a builder directly; it belongs in test/builds.tsv: $BUILDERS"

# The canary. A scan whose glob has stopped matching reports the same green as a
# workflow with nothing wrong in it, which is the shape this file has been caught
# in four times -- so it says how much it read.
NWF="$(printf '%s\n' $NT_WF | grep -c . || true)"
NBUILD="$(grep -c 'run\.sh --build' "$ROOT"/.github/workflows/ci.yml 2>/dev/null || echo 0)"
if [ "$NWF" -gt 0 ] && [ "$NBUILD" -gt 0 ]; then
    ok "the workflow scan reads the tree ($NWF workflows, $NBUILD registry builds in ci.yml)"
else
    bad "the workflow scan read $NWF workflows and found $NBUILD registry builds, so the check above proves nothing"
fi

# And nothing rewrites a built artifact, anywhere the launcher's own suites live.
PATCHED=""
for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/test/*.tsv \
         "$ROOT"/test/*.sh "$ROOT"/test/suite/* "$ROOT"/test/lib/* \
         "$ROOT"/test/build/* "$ROOT"/test/report/* "$ROOT"/test/apparatus/*; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = selftest.sh ] && continue
    # Comment lines first, and the same limitation the verdict scan documents:
    # a `#` inside a string is a comment to this and is not one to the shell.
    # The price is the right way round -- a file that explains the practice it
    # replaced reads as clean, and the practice itself does not. Both languages
    # scanned here spell a comment `#`, which is why one strip serves.
    #
    # The match is taken as text and not with `grep -q`, and that is this
    # file's own hazard rather than a style. `set -o pipefail` is on, `grep -q`
    # exits at its first hit, and the strip upstream of it then dies of SIGPIPE
    # -- so the pipeline returned 141, the `if` was false for every file in the
    # tree, and the scan reported the same green whether or not anything in the
    # tree patched an artifact. Written that way, caught by putting a `sed -i`
    # back and watching this pass. That is the fifth time in this file.
    nt_hit="$(grep -vE '^[[:space:]]*#' "$f" 2>/dev/null |
              grep -E "sed -i.*\.cmd|-i(\.bak)?[ ']+.*\.cmd" || true)"
    [ -z "$nt_hit" ] || PATCHED="$PATCHED $(basename "$f")"
done
[ -z "$PATCHED" ] \
    && ok "nothing rewrites an assembled .cmd in place" \
    || bad "an assembled artifact is patched after it is built:$PATCHED"

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
