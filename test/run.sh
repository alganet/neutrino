#!/bin/bash
# run.sh - one lane, from a manifest.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Usage: run.sh [--list] [--dry-run] <lane>[:<phase>] [suite ...]
#        run.sh --build <artifact> ...
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
#   the name    Every row exports its own $NT_SUITE, so the harness files under
#               the name the manifest gave the row rather than under the script
#               that implements it. This was the one thing the first draft of
#               this file said it deliberately did not do; the note at the call
#               site says what changed and what it cost to check.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SUITES_FILE="${NT_SUITES_FILE:-$HERE/suites.tsv}"
LANES_FILE="${NT_LANES_FILE:-$HERE/lanes.tsv}"
BUILDS_FILE="${NT_BUILDS_FILE:-$HERE/builds.tsv}"

LIST=0
DRY=0
BUILD_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)    LIST=1; shift ;;
        --dry-run) DRY=1; shift ;;
        --build)   BUILD_ONLY=1; shift ;;
        --) shift; break ;;
        -*) echo "run.sh: unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done

[ $# -ge 1 ] || { echo "usage: run.sh [--list] [--dry-run] <lane>[:<phase>] [suite ...]" >&2
                  echo "       run.sh --build <artifact> ..." >&2; exit 2; }

# --build names artifacts and not a lane. It takes `<slot>=<build>`: a build is
# a row in builds.tsv and a slot is what this copy of it is called. Neither has
# a lane, a suite or a display, so none of the manifest reading below is on its
# path. This is the door a `shell: bash` build step reaches for on a lane
# whose suites are still pwsh and cannot be manifest rows yet -- the build was
# never the part that had to stay in the workflow, only the step that runs it.
if [ "$BUILD_ONLY" = 1 ]; then
    LANE_KEY=""
    NT_LANE="${NT_LANE:-local}"
    export NT_LANE
else

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

fi

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
# The rows this lane runs, in file order. A row names its lanes in column two,
# space separated, or `*` for all of them -- the same spelling cases.tsv uses
# for `applies-to`, and for the same reason: the list is the fact, and a row per
# lane made five copies of it.
nt_rows() {
    awk -F'\t' -v lane="$LANE_KEY" '
        /^#/ { next }
        NF == 0 { next }
        {
            hit = ($2 == "*")
            if (!hit) {
                n = split($2, ls, " ")
                for (i = 1; i <= n; i++) if (ls[i] == lane) hit = 1
            }
            if (!hit) next
            setup = ($3 == "" ? "-" : $3)
            cmd   = ($4 == "" ? "-" : $4)
            printf "%s\t%s\t%s\n", $1, setup, cmd
        }
    ' "$SUITES_FILE"
}

# What the lane is, as opposed to what it runs.
DEFAULTS="$(awk -F'\t' -v lane="$LANE_KEY" '
    !/^#/ && NF && $1 == lane { print $2; exit }' "$LANES_FILE")"

if [ "$BUILD_ONLY" = 0 ] && [ -z "$(nt_rows)" ]; then
    echo "run.sh: no rows for lane '$LANE_KEY' in $SUITES_FILE" >&2
    exit 2
fi

# ------------------------------------------------------------------- the builds

BUILT=""

# Where a built artifact lands, and the one place that decides it.
#
# They sat in test/ itself until now, which put twenty-seven build outputs and
# their app folders in the corridor between the six rooms -- and cost .gitignore
# fifty-four hand-written lines, one pair per artifact, that nothing checked.
# One room, one ignore rule.
OUT_DIR="$HERE/out"

# The cache. An artifact is built once per (builder, source, flags) and copied to
# every slot that wants it, because seven suites are built from
# neutrinoloaders.js --testing and the file is byte-identical every time.
#
# This is not an optimisation of a thing that was fast. Nothing cached before:
# $BUILT is a shell variable and CI invokes this file once per suite, so
# neutrinotest.js release was assembled three times on gjs alone. Copying a
# built artifact is what test/suite/standalone.ps1 already does to get two apps
# out of one build.
CACHE_DIR="$OUT_DIR/.cache"

# One file per build, named after it rather than hashed, so a stale entry is
# something a person can look at and recognise.
nt_cache_path() {
    printf '%s/%s.cmd' "$CACHE_DIR" \
        "$(printf '%s-%s-%s' "$1" "$2" "$3" | tr -c 'A-Za-z0-9._-' '-')"
}

# nt_build <slot> <build>: put a copy of <build> at test/out/<slot>.cmd.
#
# Two arguments and not one, because they are two different things. <build> is a
# row in builds.tsv -- what to assemble. <slot> is what this copy is called, and
# it is the suite's name, so appcache runs test/out/appcache.cmd. Seven suites
# name loaders-testing and each gets its own file and its own app folder beside
# it, which is what the launcher derives from the filename and what keeps two
# suites from reading each other's trace.
nt_build() {
    local slot="$1" name="$2" line builder source flags out cache nt_f nt_ov nt_newer
    # Memoised. A lane runs five suites off four artifacts and the same one is
    # named by two rows; building it twice is thirty seconds of a runner for a
    # file that is already on disk and byte-identical.
    case " $BUILT " in *" $slot=$name "*) return 0 ;; esac

    line="$(awk -F'\t' -v n="$name" '!/^#/ && NF && $1 == n { print; exit }' "$BUILDS_FILE")"
    [ -n "$line" ] || { echo "  FAIL: no build '$name' in $BUILDS_FILE"; return 1; }

    builder="$(printf '%s' "$line" | awk -F'\t' '{print $2}')"
    source="$(printf '%s' "$line" | awk -F'\t' '{print $3}')"
    flags="$(printf '%s' "$line" | awk -F'\t' '{print $4}')"
    [ "$flags" = "-" ] && flags=""
    out="$OUT_DIR/$slot.cmd"
    # assemble.sh refuses an output whose directory does not exist, and says so
    # rather than creating it -- the artifact's path is the caller's statement
    # about where it wants the file, not a request to build a tree.
    mkdir -p "$OUT_DIR" "$CACHE_DIR" || return 1

    cache="$(nt_cache_path "$builder" "$source" "$flags")"
    # Stale if anything the build reads is newer than the entry. A person
    # editing neutrinofoo.js expects the next run to see it; CI checks out once
    # and never edits, so this costs one find and saves the rebuild.
    if [ -f "$cache" ]; then
        nt_newer="$(find "$ROOT/neutrino" "$HERE/probe" "$ROOT/pages" \
            -newer "$cache" -print 2>/dev/null | head -1 || true)"
        [ -z "$nt_newer" ] || rm -f "$cache"
    fi
    if [ -f "$cache" ]; then
        cp "$cache" "$out" || return 1
        BUILT="$BUILT $slot=$name"
        return 0
    fi

    # The builder is in build/ and the source is in probe/, and neither room is
    # spelled in builds.tsv. That table names a build, a builder and a source by
    # name; where each of those lives is this runner's business, and a manifest
    # that carried the paths would have to be re-edited by every move.
    case "$builder" in
        mkapp)
            # The flags column is argv, and a bare `--overlay <name>` in it
            # names a directory in probe/ the same way `source` names a file
            # there. It is resolved here for the reason the rooms are not in the
            # manifest at all -- and because the alternative, a path relative to
            # whatever directory the caller happened to be in, is what the
            # workflow spelled before this file existed.
            set --
            nt_ov=0
            for nt_f in $flags; do
                if [ "$nt_ov" = 1 ]; then
                    set -- "$@" "$HERE/probe/$nt_f"; nt_ov=0
                elif [ "$nt_f" = "--overlay" ]; then
                    set -- "$@" "$nt_f"; nt_ov=1
                else
                    set -- "$@" "$nt_f"
                fi
            done
            if [ "$nt_ov" = 1 ]; then
                echo "  FAIL: build '$name' ends its flags with a bare --overlay"; return 1
            fi
            # ${1+"$@"} and not "$@": with no flags at all and `set -u`, the
            # bare form is an unbound variable on the bash 3.2 macOS ships,
            # which is the same reason nothing in this tree uses an array.
            bash "$HERE/build/mkapp.sh" ${1+"$@"} "$HERE/probe/$source" "$cache" || return 1 ;;
        demoapp)
            bash "$HERE/build/demoapp.sh" "$cache" || return 1 ;;
        *)
            echo "  FAIL: build '$name' names an unknown builder '$builder'"; return 1 ;;
    esac

    # Once per build and not once per slot: the copies are the same bytes.
    bash "$HERE/build/parse.sh" "$cache" || { rm -f "$cache"; return 1; }
    cp "$cache" "$out" || return 1
    BUILT="$BUILT $slot=$name"
    return 0
}

# --build ends here: the artifacts named on the command line, each built and
# parsed exactly as a lane would have built it, and an exit status that is the
# number that failed. No suite runs and no display is asked for.
if [ "$BUILD_ONLY" = 1 ]; then
    NT_BUILD_RC=0
    # `<slot>=<build>` names both, which is what the pwsh lanes want: they run
    # `.\test\out\appcache.cmd` and the step above them should say which build
    # that is. A bare `<build>` is the local convenience -- the slot is the
    # build's own name.
    for nt_name in "$@"; do
        case "$nt_name" in
            *=*) nt_slot_name="${nt_name%%=*}"; nt_build_name="${nt_name#*=}" ;;
            *)   nt_slot_name="$nt_name"; nt_build_name="$nt_name" ;;
        esac
        echo "::group::build $nt_slot_name ($nt_build_name)"
        if nt_build "$nt_slot_name" "$nt_build_name"; then
            echo "  built $nt_slot_name from $nt_build_name"
        else
            NT_BUILD_RC=$((NT_BUILD_RC + 1))
        fi
        echo "::endgroup::"
    done
    [ "$NT_BUILD_RC" = 0 ] || echo "run.sh: $NT_BUILD_RC artifact(s) did not build" >&2
    exit "$NT_BUILD_RC"
fi

# ---------------------------------------------------------------- the directives

# Turn a setup column into step.sh's argv. The defaults row is parsed first and
# the row's own setup after it, so a row saying display=none overrides a lane
# saying display=metacity by plain left-to-right assignment.
#
# An unknown directive is an error. A typo that is quietly ignored is a suite
# running without the display it asked for, which fails later as "no window
# appeared" -- a sentence about the app.
STEP_ARGS=""
APP_SPEC=""
REAP_PREFIX=""
BUILD_SPECS=""
SETUP_BAD=""
SOFT=0

nt_setup() {
    local wm="" tk="" leash="" cats="" dbus="" toolkit="" nodisp=0 d
    APP_SPEC=""; BUILD_SPECS=""; REAP_PREFIX=""; SETUP_BAD=""; SOFT=0
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
            # Both name a build in builds.tsv, optionally with a slot in front
            # of it: `build=<build>` is this suite's own copy and
            # `build=<slot>:<build>` a second one beside it, for the ten rows
            # that compare two builds. The path is derived from the suite in
            # both cases -- see nt_slot below.
            #
            # app= is build= plus one thing: step.sh launches that artifact,
            # reaps it and exports its pid, and the command column then names
            # only the verifier. build= is for the artifacts the command is
            # handed instead, which is why only those are appended to it.
            app=*)     APP_SPEC="${d#app=}"; BUILD_SPECS="$BUILD_SPECS ${d#app=}" ;;
            build=*)   BUILD_SPECS="$BUILD_SPECS ${d#build=}" ;;
            cat=*)     cats="$cats --cat ${d#cat=}" ;;
            # A session bus around the artifact test/lib/step.sh launches. kde asks
            # for one because QtWebEngine wants a bus and the container has no
            # desktop to inherit one from; nothing else does. It is a directive
            # rather than an env(1) in the command column for the reason the
            # header gives about that column: the command is the verifier, and
            # the artifact is launched by step.sh.
            dbus)      dbus=" --dbus" ;;
            # The toolkit this lane draws with, declared once in its `*` row.
            # It reached ten suites as an argv word sitting beside a setup
            # column that already said `gtk` or `qt` -- and macos, which says
            # neither, spelled it in the command column five times.
            toolkit=*) toolkit="${d#toolkit=}" ;;
            # Only the window-title prefix now. The other half was the
            # artifact's basename spelled by hand -- reap.sh pgreps it against
            # command lines, and the runner is the thing that just decided what
            # that basename is.
            reap=*)    REAP_PREFIX="${d#reap=}" ;;
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
    [ -n "$cats" ] && STEP_ARGS="$STEP_ARGS$cats"
    [ -n "$dbus" ] && STEP_ARGS="$STEP_ARGS$dbus"
    [ -n "$toolkit" ] && STEP_ARGS="$STEP_ARGS --toolkit $toolkit"
    return 0
}

# A spec is `<build>` or `<slot>:<build>`; this turns it into the artifact's
# name. Bare is the suite itself -- appcache runs test/out/appcache.cmd -- and a
# slot hangs off it, so loaders' second artifact is test/out/loaders-default.cmd.
# The name is what the launcher derives the app folder and the Windows process
# name from, so two suites sharing a build still get two of each.
nt_slot() {
    case "$1" in
        *:*) printf '%s-%s' "$2" "${1%%:*}" ;;
        *)   printf '%s' "$2" ;;
    esac
}
nt_spec_build() { printf '%s' "${1##*:}"; }

# ----------------------------------------------------------------------- the run

FAILURES=0
TIMINGS=""
RAN=0

while IFS="$(printf '\t')" read -r suite setup command; do
    [ -n "$suite" ] || continue
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
    if [ -n "$APP_SPEC" ]; then
        nt_app_slot="$(nt_slot "$APP_SPEC" "$suite")"
        APP_ARG="--app $OUT_DIR/$nt_app_slot.cmd"
        # step.sh names the launcher's own log after the artifact, so three rows
        # spelled `cat=neutrinotest-app` to get it into the job log -- a name
        # derived in one file and written out in another, tracking the artifact
        # filename rather than the row. The artifact is the suite's now, so this
        # is the suite's too, and it needs saying in neither place.
        APP_ARG="$APP_ARG --cat $nt_app_slot-app"
        [ -z "$REAP_PREFIX" ] || APP_ARG="$APP_ARG --reap $nt_app_slot:$REAP_PREFIX"
    fi

    # The artifacts the command is handed, appended in the order the row names
    # them. They were spelled out in twenty-nine command columns and in every
    # one of them the path was a thing the runner had just built and already
    # knew -- so a row said `neutrinostdgeom.cmd` and nothing checked that any
    # build produced it. A suite's argv is unchanged: it still reads $1 and $2.
    ART_ARGS=""
    for nt_s in $BUILD_SPECS; do
        [ "$nt_s" = "$APP_SPEC" ] && continue
        ART_ARGS="$ART_ARGS $OUT_DIR/$(nt_slot "$nt_s" "$suite").cmd"
    done

    if [ "$DRY" = 1 ]; then
        echo "$suite: bash $HERE/lib/step.sh$STEP_ARGS --log $suite $APP_ARG -- $command$ART_ARGS"
        continue
    fi

    echo "::group::$suite"
    echo "### $suite"
    SUITE_T0=$SECONDS
    RC=0

    # The row's name, for the harness to file under.
    #
    # Without this a suite is named by the script that implements it, because
    # that is all harness.sh has to go on -- `basename "${0%.sh}"`. Four rows on
    # every desktop lane run test/suite/verify-std.sh, so stddoc, stdwin, stdtheme and
    # stdfont all filed as `verify-std`, appending to one file; the sheet's
    # per-case table then had a suite column that could not say which of the four
    # a row came from, and neither could a reader. fontflip and fontlive are the
    # same script twice, and the halves of the geometry and theme flips reach
    # verify-std.sh through decoflip.sh and themeflip.sh, so their rows landed in
    # that same pile as well.
    #
    # It moves no cell in the grid, and that is worth saying because it was the
    # stated reason for not doing it. test/report/sheet.sh builds its digest from
    # (id, verdict, suite) triples, but test/report/matrix.py reads the id and the
    # verdict and never the suite -- so the name reaches the sheet's own table
    # and stops there. Nothing globs these files by name either: sheet.sh takes
    # `*.tsv` from the directory it is pointed at.
    #
    # Exported and not passed, for the reason harness.sh derives it in the first
    # place: a call site that had to repeat its own name is a call site that can
    # come to disagree with the manifest. A row whose suite runs another suite
    # hands the name down, which is the right answer -- the manifest's row is
    # what the lane was asked for, and the script underneath it is an
    # implementation detail the grid has never had a use for.
    #
    # Two PowerShell suites set $env:NT_SUITE for themselves, and they are the
    # thing to look at when windows-content and windows-launch migrate. They do
    # it for this exact defect one level down -- they hand a record to bash, and
    # $0 there is analyse.sh or walk.sh -- but they assign rather than default,
    # so an inherited name loses. verify-windows.ps1 is right to: it runs three
    # times in one job and names the three apart, which is finer than a row can.
    # verify-std.ps1 spells the literal `verify-std`, which is the name this
    # line exists to stop using, and it will quietly win over the manifest on
    # the day that row is written.
    export NT_SUITE="$suite"

    for nt_s in $BUILD_SPECS; do
        nt_build "$(nt_slot "$nt_s" "$suite")" "$(nt_spec_build "$nt_s")" || { RC=1; break; }
    done

    if [ "$RC" = 0 ]; then
        # shellcheck disable=SC2086
        bash "$HERE/lib/step.sh" $STEP_ARGS --log "$suite" $APP_ARG -- $command $ART_ARGS
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
