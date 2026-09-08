#!/bin/bash
# run.sh - one lane, from a manifest.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Usage: run.sh [--list] [--dry-run] <lane>[:<phase>] [suite ...]
#
# test/lib/harness.sh has referred to this file since it was written -- "what CI
# and test/run.sh set", "test/run.sh relies on it to add a lane up without
# parsing anything" -- and it did not exist. The runner was .github/workflows/ci.yml:
# 153 steps invoking 45 scripts, of which 84 lines were mkapp.sh and 54 were
# parse.sh. A workflow is a bad place to keep a test framework, because the only
# way to run a lane the way CI runs it was to be CI.
#
# netinstall/test/run.sh has been the other tree's runner all along, and this is
# deliberately built to look like it: a declared list, a leash per suite, a
# heading and a timing line each, an exit status that is the failure count. Two
# runners that look alike is a feature -- an author who has read one can read the
# other -- so where there was a choice, it went the way netinstall already goes.
#
# What this adds, and why:
#
#   ::group::   A lane is one step now. Thirty collapsible sections in the GitHub
#               UI would have become one wall of text, and the folding is not a
#               nicety: it is how anybody finds the suite that failed.
#
#   the build   Every artifact is built and parsed here rather than in the step
#               that runs it. parse.sh was a per-step choice in fifty-four
#               places and should never have been one -- an artifact that does
#               not parse is a suite that measures nothing, and hearing it from
#               the suite is hearing it late.
#
# What it deliberately does not do is set $NT_SUITE per row. It would be an
# improvement: verify-std.sh serves four rows and all four file under
# `verify-std`, so the sheet's per-case table cannot say which of them a row came
# from.
#
# It was left out on the reasoning that it renames every .tsv a lane writes and
# would therefore destroy the baseline grid comparison that proves each change
# safe. That reason does not survive being checked. test/sheet.sh builds the
# digest from (id, verdict, suite) triples but test/matrix.py reads only the id
# and the verdict, so the suite name reaches the sheet's own table and never the
# grid: renaming the files moves no cell. The change is still a follow-up rather
# than a freebie -- it wants its own commit and its own probe -- but the thing
# that was thought to block it does not.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUITES_FILE="${NT_SUITES_FILE:-$HERE/suites.tsv}"
APPS_FILE="${NT_APPS_FILE:-$HERE/apps.tsv}"

LIST=0
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)    LIST=1; shift ;;
        --dry-run) DRY=1; shift ;;
        --) shift; break ;;
        -*) echo "run.sh: unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done

[ $# -ge 1 ] || { echo "usage: run.sh [--list] [--dry-run] <lane>[:<phase>] [suite ...]" >&2; exit 2; }

LANE_KEY="$1"; shift
# Everything left of the colon is the lane. A phase is how one lane runs its list
# more than once -- linux-engines swaps engine packages between halves -- and it
# must not reach $NT_LANE, or cases.tsv and the grid would grow a lane that does
# not exist.
NT_LANE="${NT_LANE:-${LANE_KEY%%:*}}"
export NT_LANE

# The selection, which is what makes a half-migrated lane safe: a row that exists
# in the manifest and is not named here does not run, so a step the workflow
# still spells out by hand is not also run from here. Same escape, and the same
# reason for it, as netinstall/test/run.sh's $NEUTRINO_SUITES.
WANTED="$*"
# NT_RUN_SUITES and not NT_SUITES: test/lib/selftest.sh already uses $NT_SUITES
# for a list of suite *file paths*, and it is one `export` away from being read
# here as a selection of suite names -- which would match nothing and run
# nothing, silently. Two meanings for one name in one tree is the bug this
# runner exists to make harder, so it does not open with one.
[ -n "${NT_RUN_SUITES:-}" ] && WANTED="$NT_RUN_SUITES"

[ -f "$SUITES_FILE" ] || { echo "run.sh: no manifest at '$SUITES_FILE'" >&2; exit 2; }

# ------------------------------------------------------------------ the manifest

# awk -F'\t' and not a read loop with IFS: the command column holds spaces and
# the setup column holds several words, and a BSD sed has no \t to split on.
#
# The `-` for an empty setup column is not cosmetic, and it cost a debugging
# round to find. Tab is IFS *whitespace*, and bash collapses a run of IFS
# whitespace into one delimiter -- so `suite<TAB><TAB>command` reaches `read` as
# two fields and the command lands in the setup variable, where it is then
# reported as an unknown directive. Every field this emits is non-empty for that
# reason alone.
nt_rows() {
    awk -F'\t' -v lane="$LANE_KEY" '
        /^#/ { next }
        NF == 0 { next }
        $1 == lane {
            setup = ($3 == "" ? "-" : $3)
            cmd   = ($4 == "" ? "-" : $4)
            printf "%s\t%s\t%s\n", $2, setup, cmd
        }
    ' "$SUITES_FILE"
}

DEFAULTS="$(nt_rows | awk -F'\t' '$1 == "*" { print $2; exit }')"

if [ -z "$(nt_rows)" ]; then
    echo "run.sh: no rows for lane '$LANE_KEY' in $SUITES_FILE" >&2
    exit 2
fi

# ------------------------------------------------------------------- the builds

BUILT=""

# The artifact's filename for a row, defaulting to the row's own name.
nt_app_out() {
    awk -F'\t' -v n="$1" '!/^#/ && NF && $1 == n {
        print ($5 == "" || $5 == "-") ? n ".cmd" : $5; exit
    }' "$APPS_FILE"
}

nt_build() {
    local name="$1" line builder source flags outname out
    # Memoised. A lane runs five suites off four artifacts and the same one is
    # named by two rows; building it twice is thirty seconds of a runner for a
    # file that is already on disk and byte-identical.
    case " $BUILT " in *" $name "*) return 0 ;; esac

    line="$(awk -F'\t' -v n="$name" '!/^#/ && NF && $1 == n { print; exit }' "$APPS_FILE")"
    [ -n "$line" ] || { echo "  FAIL: no artifact '$name' in $APPS_FILE"; return 1; }

    builder="$(printf '%s' "$line" | awk -F'\t' '{print $2}')"
    source="$(printf '%s' "$line" | awk -F'\t' '{print $3}')"
    flags="$(printf '%s' "$line" | awk -F'\t' '{print $4}')"
    outname="$(printf '%s' "$line" | awk -F'\t' '{print $5}')"
    [ "$flags" = "-" ] && flags=""
    [ -z "$outname" ] || [ "$outname" = "-" ] && outname="$name.cmd"
    out="$HERE/$outname"

    case "$builder" in
        mkapp)
            # shellcheck disable=SC2086
            bash "$HERE/mkapp.sh" $flags "$HERE/$source" "$out" || return 1 ;;
        demoapp)
            bash "$HERE/demoapp.sh" "$out" || return 1 ;;
        *)
            echo "  FAIL: artifact '$name' names an unknown builder '$builder'"; return 1 ;;
    esac

    bash "$HERE/parse.sh" "$out" || return 1
    BUILT="$BUILT $name"
    return 0
}

# ---------------------------------------------------------------- the directives

# Turn a setup column into step.sh's argv. The defaults row is parsed first and
# the row's own setup after it, so a row saying display=none overrides a lane
# saying display=metacity by plain left-to-right assignment.
#
# An unknown directive is an error. A typo that is quietly ignored is a suite
# running without the display it asked for, which fails later as "no window
# appeared" -- a sentence about the app.
STEP_ARGS=""
APP_NAME=""
BUILD_NAMES=""
SETUP_BAD=""
SOFT=0

nt_setup() {
    local wm="" tk="" leash="" reap="" cats="" dbus="" nodisp=0 d
    APP_NAME=""; BUILD_NAMES=""; SETUP_BAD=""; SOFT=0
    for d in $1 $2; do
        [ "$d" = "-" ] && continue
        case "$d" in
            # `display=off` is not `display=none`, and the difference cost a
            # reading to notice. test/lib/display.sh's `none` means an X server
            # with no window manager -- it is for the lanes that assert on the
            # walk rather than on the frame, and it still starts Xvfb. `off` is
            # this file's word for a suite that wants no display at all:
            # lanes.sh drives stub engines and assemble.sh reads files, and
            # neither had a DISPLAY in the workflow. It clears the toolkit too,
            # because a lane default that says `gtk` is saying it about the
            # suites that open a window.
            display=off) wm=""; tk=""; nodisp=1 ;;
            display=*) wm="${d#display=}"; nodisp=0 ;;
            # Both, where a lane asks for both. kde's default is Qt, but its
            # attack step exports GDK_BACKEND as well, because the probe it
            # launches is reached through the GTK walk on that machine. So these
            # accumulate rather than overwrite -- a row saying `gtk` on a Qt lane
            # is adding a toolkit, not choosing one.
            gtk)       case "$tk" in *--gtk*) ;; *) tk="$tk --gtk" ;; esac ;;
            qt)        case "$tk" in *--qt*) ;; *) tk="$tk --qt" ;; esac ;;
            timeout=*) leash="${d#timeout=}" ;;
            app=*)     APP_NAME="${d#app=}"; BUILD_NAMES="$BUILD_NAMES ${d#app=}" ;;
            build=*)   BUILD_NAMES="$BUILD_NAMES ${d#build=}" ;;
            cat=*)     cats="$cats --cat ${d#cat=}" ;;
            # A session bus around the artifact test/step.sh launches. kde asks
            # for one because QtWebEngine wants a bus and the container has no
            # desktop to inherit one from; nothing else does. It is a directive
            # rather than an env(1) in the command column for the reason the
            # header gives about that column: the command is the verifier, and
            # the artifact is launched by step.sh.
            dbus)      dbus=" --dbus" ;;
            reap=*)    reap="${d#reap=}" ;;
            # continue-on-error, spelled once. Four steps carry it in the
            # workflow and every one of them is a probe: it reports a reading
            # nobody asserts, so a red one is a lane that measured something
            # rather than a lane that failed.
            soft)      SOFT=1 ;;
            *)         SETUP_BAD="$d"; return 1 ;;
        esac
    done
    STEP_ARGS=""
    [ "$nodisp" = 1 ] && { wm=""; tk=""; }
    [ -n "$wm" ]    && STEP_ARGS="$STEP_ARGS --display $wm"
    [ -n "$tk" ]    && STEP_ARGS="$STEP_ARGS $tk"
    [ -n "$leash" ] && STEP_ARGS="$STEP_ARGS --timeout $leash"
    [ -n "$reap" ]  && STEP_ARGS="$STEP_ARGS --reap $reap"
    [ -n "$cats" ] && STEP_ARGS="$STEP_ARGS$cats"
    [ -n "$dbus" ] && STEP_ARGS="$STEP_ARGS$dbus"
    return 0
}

# ----------------------------------------------------------------------- the run

FAILURES=0
TIMINGS=""
RAN=0

while IFS="$(printf '\t')" read -r suite setup command; do
    [ -n "$suite" ] || continue
    [ "$suite" = "*" ] && continue
    if [ -n "$WANTED" ]; then
        case " $WANTED " in *" $suite "*) ;; *) continue ;; esac
    fi

    if [ "$command" = "-" ]; then
        echo "  FAIL: $suite has no command"
        FAILURES=$((FAILURES + 1))
        continue
    fi

    if ! nt_setup "$DEFAULTS" "$setup"; then
        echo "  FAIL: $suite names an unknown setup directive '$SETUP_BAD'"
        FAILURES=$((FAILURES + 1))
        continue
    fi

    if [ "$LIST" = 1 ]; then
        echo "$suite"
        continue
    fi

    APP_ARG=""
    if [ -n "$APP_NAME" ]; then
        # The filename apps.tsv gives it, which is not always the row's name:
        # neutrinotest-release and neutrinotest-testing both write
        # neutrinotest.cmd.
        APP_ARG="--app $HERE/$(nt_app_out "$APP_NAME")"
    fi

    if [ "$DRY" = 1 ]; then
        echo "$suite: bash $HERE/step.sh$STEP_ARGS --log $suite $APP_ARG -- $command"
        continue
    fi

    echo "::group::$suite"
    echo "### $suite"
    SUITE_T0=$SECONDS
    RC=0

    for a in $BUILD_NAMES; do
        nt_build "$a" || { RC=1; break; }
    done

    if [ "$RC" = 0 ]; then
        # shellcheck disable=SC2086
        bash "$HERE/step.sh" $STEP_ARGS --log "$suite" $APP_ARG -- $command
        RC=$?
    fi

    RAN=$((RAN + 1))
    SUITE_SECS=$((SECONDS - SUITE_T0))
    TIMINGS="$TIMINGS$(printf '%5ds  %s\n' "$SUITE_SECS" "$suite")
"
    if [ "$RC" != 0 ] && [ "$SOFT" = 1 ]; then
        # Said, and not counted. The reading is still in the log and the
        # pictures are still in the sheet; what a probe must not do is turn a
        # lane red for having measured something.
        echo "  $suite: $RC failure(s), not counted (soft)"
        RC=0
    fi

    if [ "$RC" != 0 ]; then
        echo "  $suite: $RC failure(s)"
        # A red step used to name itself in the GitHub UI. A red lane names the
        # lane, so the suite has to say so itself -- and only on a failure,
        # because annotations are capped at thirty per job and dropped silently.
        [ -n "${GITHUB_ACTIONS:-}" ] &&
            echo "::error title=$NT_LANE::$suite reported $RC failure(s)"
    fi
    FAILURES=$((FAILURES + RC))
    echo "::endgroup::"
done <<EOF
$(nt_rows)
EOF

[ "$LIST" = 1 ] && exit 0
[ "$DRY" = 1 ] && exit 0

if [ "$RAN" = 0 ]; then
    echo "run.sh: no suite ran for lane '$LANE_KEY'" >&2
    [ -n "$WANTED" ] && echo "run.sh: the selection was '$WANTED'" >&2
    exit 2
fi

echo
echo "### Where the time went"
printf '%s' "$TIMINGS" | sort -rn
echo
echo "### Total: $FAILURES failure(s)"
exit "$FAILURES"
