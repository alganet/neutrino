# live.sh - the shape of a live half, which four of them already had.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Sourced, below lib/title.sh, which these read titles through.
#
# A *live* half is the one question a launch-and-compare pair cannot ask. Both
# halves of a flip start an app after the desktop moved, and every value this
# project delivers is read at startup -- so both halves pass with the watcher
# dead, and on macOS both did. That driver's two notification registrations
# passed `null` where ObjC wanted nil; the distributed centre raised on it and
# the local one took the NSNull quietly as an object filter nothing could match.
# It never raised and it never fired, and the differential was green through all
# of it, because it never had a running app to flip underneath.
#
# So a live half starts the app *first* and moves the desktop after. There are
# four of them:
#
#   themeflip.sh  live_half_gtk    the desktop's accent, through XSettings
#   themeflip.sh  live_half_qt     a Plasma colour scheme, through DBus
#   themeflip.sh  live_half        the macOS appearance switch
#   fontflip.sh   live_half_gtk    the ui and monospace font roles
#
# ---------------------------------------------------------- what they share
#
# Eight steps, in this order, in all four:
#
#   1  can this machine ask the question at all
#   2  save the knob, and arrange to put it back on every path out
#   3  prove the knob moves something of the suite's own -- the control
#   4  build the probe if it is not already built
#   5  launch it, and wait for its first title
#   6  refuse to go on if that title says the probe read no toolkit
#   7  flip, and wait for the title to say it moved
#   8  the verdict
#
# Steps 1, 2, 3 and 7's flip are where the four genuinely differ: they are the
# knob, and a knob is the platform. Steps 4, 5, 6, 7's wait and 8 are the same
# work four times over, and they had already drifted -- harness.sh's header
# names this exact set as evidence that a sentence cannot be an assertion's
# identity, because "the four copies of the live-half check disagree about a
# `live half: ` prefix".
#
# ------------------------------------------------- what is deliberately not here
#
# Verdict words. These print the `PASS:`/`FAIL:` lines the four copies printed,
# because themeflip.sh and fontflip.sh do not speak the harness yet and what
# reaches the grid from them is a question with an open answer -- fontflip's
# `fontflip` row is `soft` on all three lanes that run it and its `fontlive` row
# is not, so a case id filed here would redden a cell for a lane that
# deliberately does not count it. When those files convert, this is the one
# place the ids go, which is the point of the move.

# The tree, for the builder. Taken from this file's own path rather than from a
# caller's $ROOT, because both callers already compute one and a third spelling
# is a third thing that can be wrong.
NT_LIVE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"

# The probe, built where the caller did not hand one in.
#
# Every copy of this defaulted its artifact rather than requiring one, and for a
# reason worth keeping: a caller that predates a probe should run the half
# anyway instead of silently not running it. CI names the artifact regardless,
# so it goes through parse.sh with the others.
#
# `-f` and not `-r`: fontflip.sh's copy asked whether the file was readable and
# the other three whether it existed, which are the same answer on every machine
# that has got as far as running this and a different one on the machine where
# it matters -- a file that exists and cannot be read is rebuilt over by `-r`
# and reported by `-f`.
nt_live_build() {
    [ -f "$2" ] && return 0
    nt_report "live half: building $2"
    bash "$NT_LIVE_ROOT/test/mkapp.sh" --testing "$1" "$2" && return 0
    echo "FAIL: live half: could not build the live probe"
    return 1
}

# Start it, and wait for it to say something.
#
# By title and not by pid, in every copy and for the same reason: the .cmd execs
# an interpreter, so the process holding the window is a child whose pid this
# shell never learns. $NT_LIVE_PID is the launcher, and killing it means killing
# its children too -- which is what nt_live_stop is for.
#
# The wait is a second per turn because that is what all four spent, and the
# budgets they spent it for differ by an order of magnitude between platforms:
# 90 turns on a GTK desk, 180 where a Qt container or a WKWebView content
# process has to come up first. So it is the caller's number.
#
# The status file is cleared before the launch on macOS, and that clear is not
# optional: it is read through one fixed path, so a line left by an earlier half
# is a reading attributed to this one.
nt_live_start() {
    local js="$1" art="$2" log="$3"
    nt_live_build "$js" "$art" || return 1
    [ "$NT_TITLE_HOW" = status ] && rm -f "$NT_STATUS_FILE"
    bash "$art" > "$log" 2>&1 &
    NT_LIVE_PID=$!
    return 0
}

# Every way out of a live half goes through this, including the ones that give
# up before the flip. A half that returns leaving its app on screen hands the
# next thing to read a title of the same shape as its own -- which is the hazard
# the whole nt_title_gone dance exists for, arriving from the one direction that
# dance cannot see.
nt_live_stop() {
    [ -n "${NT_LIVE_PID:-}" ] || return 0
    pkill -P "$NT_LIVE_PID" 2>/dev/null || true
    kill "$NT_LIVE_PID" 2>/dev/null || true
    NT_LIVE_PID=""
    return 0
}

# The first reading, and the two things that make it unusable.
#
# The title lands in $NT_LIVE_TITLE rather than on stdout, because the failure
# lines below are on stdout too and a caller cannot have both out of one
# substitution. That is also why the caller's restore runs in the caller: this
# returns non-zero having said what went wrong, and what has to be put back is
# the knob it never touched.
#
#   1  no title at all: the probe never came up, and there is nothing to judge
#   2  src=null: it came up and read no toolkit, so a flip would prove nothing
#
# Two failures and one question, and they belong together: both mean there is no
# reading here to judge, which is a different thing from a watcher that did not
# fire. They keep two sentences because the fixes differ.
#
# ------------------------------------------------------- with and without an id
#
# $NT_LIVE_CASE is how a suite that speaks the harness gets a verdict out of
# this, and an empty one is how the suites that do not get the prose they always
# printed. Set it through assert_live_up rather than by hand: the id is that
# function's first argument, which is what selftest.sh's registry scan follows
# -- an id reaching nt_pass through a variable is the one shape it cannot see,
# and `assert_` is the prefix it knows.
nt_live_up() {
    local prefix="$1" secs="$2" waited=0
    while [ "$waited" -lt "$secs" ]; do
        NT_LIVE_TITLE="$(nt_title "$prefix")"
        [ -n "$NT_LIVE_TITLE" ] && break
        sleep 1
        waited=$((waited + 1))
    done
    NT_LIVE_TITLE="$(nt_title "$prefix")"
    if [ -z "$NT_LIVE_TITLE" ]; then
        nt_live_say fail "live half: no $prefix window in ${secs}s; the probe never came up"
        return 1
    fi
    case "$NT_LIVE_TITLE" in
        *src=null*)
            nt_report "live before: $NT_LIVE_TITLE"
            nt_live_say fail "live half: the probe read no toolkit, so a flip would prove nothing"
            return 1 ;;
    esac
    nt_live_say pass "live before: $NT_LIVE_TITLE"
    return 0
}

# One sentence, said as a verdict where there is a case to file it under and as
# the line it always was where there is not.
#
# The passing spelling is the difference worth noting: without a case this is
# the `report: live before: ...` line every copy printed, and with one it is
# that line *and* a PASS. A case emitted only by fail and skip files nothing on
# the healthy run, which is the run it spends its life on.
nt_live_say() {
    if [ -z "${NT_LIVE_CASE:-}" ]; then
        case "$1" in
            pass) nt_report "$2" ;;
            *)    echo "FAIL: $2" ;;
        esac
        return 0
    fi
    case "$1" in
        pass) nt_report "$2"; nt_pass "$NT_LIVE_CASE" "$2" ;;
        *)    nt_fail "$NT_LIVE_CASE" "$2" ;;
    esac
}

# The same reading, filed under a case. The id comes first because that is where
# selftest.sh's scan looks, and the `assert_` prefix is what tells it to.
assert_live_up() {
    local id="$1"; shift
    NT_LIVE_CASE="$id"
    nt_live_up "$@"
    local rc=$?
    NT_LIVE_CASE=""
    return "$rc"
}

# After the flip: wait for the title to say it moved, then stop waiting whatever
# it says. $NT_LIVE_TITLE is what it ended up at, which is the reading the
# verdict reads -- including when nothing arrived, because "the probe stopped
# writing its title" is a third answer and not a variant of the second.
#
# The optional third argument is fontflip.sh's, and it is not a refinement -- it
# is that half's correctness. It flips twice, so after the second flip the title
# already says `moved=yes` from the first one, and a wait on the word alone
# returns at once and reports a watcher that never fired as working. The reading
# counter is what tells the two apart, so the wait is for `moved=yes` with at
# least N readings behind it.
#
# Half-second turns in all four, and the argument here is seconds so that the
# budget reads as one: fifteen on the three flips that wait for a desktop, ten
# on macOS, where the notification arrives in one and the wait is for a re-read,
# a diff and a script evaluation behind it.
nt_live_settle() {
    local prefix="$1" secs="$2" want="${3:-}" waited=0 turns n
    turns=$((secs * 2))
    while [ "$waited" -lt "$turns" ]; do
        NT_LIVE_TITLE="$(nt_title "$prefix")"
        case "$NT_LIVE_TITLE" in
            *moved=yes*)
                if [ -z "$want" ]; then
                    return 0
                fi
                n="$(nt_field n "$NT_LIVE_TITLE")"
                [ -n "$n" ] && [ "$n" -ge "$want" ] 2>/dev/null && return 0
                ;;
        esac
        sleep 0.5
        waited=$((waited + 1))
    done
    NT_LIVE_TITLE="$(nt_title "$prefix")"
    return 1
}

# The verdict, and there are three answers rather than two.
#
# The sentences are the caller's, because a palette moving and a colour scheme
# moving are different findings and the sentence is what a reader of a log has.
# The failure is a head and a tail with the reading count between them, which is
# how all three copies of it were already written -- the count is the difference
# between "the watcher fired once, at startup" and "it fired again", so it sits
# inside the sentence rather than after it.
#
# The third answer belongs to no lane. A title that is neither `moved=yes` nor
# this probe's at all means the app stopped reporting, which is not the watcher
# failing and must not be filed as though it were.
nt_live_verdict() {
    local prefix="$1" moved="$2" head="$3" tail="$4" n
    n="$(nt_field n "$NT_LIVE_TITLE")"
    nt_report "live after: ${NT_LIVE_TITLE:-<nothing>}"
    case "$NT_LIVE_TITLE" in
        *moved=yes*)
            echo "PASS: $moved"
            nt_report "live readings n=${n:-?}"
            return 0 ;;
        "$prefix"*)
            echo "FAIL: $head (n=${n:-?}); $tail"
            return 1 ;;
        *)
            echo "FAIL: live half: the probe stopped writing its title after the flip"
            return 1 ;;
    esac
}
