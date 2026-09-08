# harness.sh - the vocabulary every suite in test/ speaks.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Sourced, never run. `. "$(dirname "$0")/lib/harness.sh"` at the top of a suite.
#
# Until this file existed, every suite declared its own `pass`/`fail`/`report`
# -- fifteen bash files, thirty-one definitions, and seventeen PowerShell files
# in four different dialects. They did not agree: some printed `  FAIL:` and
# some `FAIL:`, and two spelled a reading `report: PASS:`, which is why
# sheet.sh strips the prefix twice and matches on `(^|[[:space:]])FAIL:`.
#
# ---------------------------------------------------------------- two channels
#
# Every call here writes twice, and the reason is the whole migration strategy.
#
# The first channel is stdout, in the spelling the suites already use. Job logs,
# sheet.sh's grep, and anybody reading a run keep working unchanged -- so a
# converted suite is a no-op on every existing reader, and the conversion can go
# one file at a time instead of as a flag day.
#
# The second is $NT_RESULTS, a TSV of one row per assertion. That row carries a
# *case id*, and the case id is the point. Today the assertion's identity is its
# sentence: sheet.sh folds every run of digits to `#` and sheetdiff.py
# intersects the results, so two lanes assert "the same thing" only when two
# languages emit the same sentence to the byte. That is an obligation nobody can
# keep by hand, and it is already broken -- verify-windows.ps1 shares no sentence
# with verify-linux.sh for the geometry and position facts both assert, and the
# four copies of the live-half check disagree about a `live half: ` prefix. A
# case id says two lanes asserted one thing without asking their prose to match.
#
# So: the detail string stays whatever the suite already printed, and the id is
# carried beside it rather than parsed back out of it.

# The lane this is running on. CI names it per job; a developer running a suite
# by hand gets `local`, which is honest -- a reading taken on a workstation is
# not a lane reading and should not be filed as one.
NT_LANE="${NT_LANE:-local}"

# The suite's own name, for the TSV's second column. Derived from $0 rather than
# passed, because every call site would otherwise repeat the filename it is
# already in, and the one that eventually disagreed would be the interesting one.
NT_SUITE="${NT_SUITE:-$(basename "${0%.sh}")}"

# Where the rows go. Unset means prose only, which is what a suite run by hand
# in a terminal wants; NT_RESULTS_DIR is what CI and test/run.sh set, so every
# suite in a lane lands its rows beside the others without any call site knowing.
if [ -z "${NT_RESULTS:-}" ] && [ -n "${NT_RESULTS_DIR:-}" ]; then
    mkdir -p "$NT_RESULTS_DIR" 2>/dev/null || true
    NT_RESULTS="$NT_RESULTS_DIR/$NT_SUITE.tsv"
fi

# Where the macOS driver writes the window title, and the one fact ten files
# were each spelling out.
#
# There is no window a shell can query on macOS, so every check that reads a
# title there reads this file instead -- and every check that launches an app
# has to clear it first, because a stale one is the previous suite's last title
# and reads as this suite's first report before the app has rendered anything.
#
# It was `${TMPDIR:-/tmp}/neutrino-title.txt` written out in ten places, against
# a name assemble.sh separately asserts appears in a testing-tier build and not
# in a default one. A path that has to agree in eleven files and a test that the
# name is present is a fact worth having once. The files that do not yet speak
# the harness still spell it; they pick this up as they convert.
NT_STATUS_FILE="${NT_STATUS_FILE:-${TMPDIR:-/tmp}/neutrino-title.txt}"

NT_FAILURES=0
NT_PASSES=0
NT_SKIPS=0

# A field with a tab or a newline in it would silently move every column after
# it, so the separator is removed rather than escaped: these are human sentences
# and a stray tab in one is never load-bearing. Carriage returns go too -- the
# Windows lanes read titles through PowerShell and a trailing \r in a detail
# string would otherwise reach the file and compare unequal to the same sentence
# taken on Linux.
nt_clean() { printf '%s' "$*" | tr -d '\t\r\n'; }

# One row. Written with >> and not held in a variable, so a suite killed by its
# timeout still leaves behind everything it had established up to that point --
# which is the run you most want the rows from.
nt_row() {
    [ -n "${NT_RESULTS:-}" ] || return 0
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$NT_LANE" "$NT_SUITE" "$(nt_clean "$1")" "$2" "$(nt_clean "$3")" \
        >> "$NT_RESULTS" 2>/dev/null || true
    return 0
}

# The three verdicts and the reading.
#
# Every one of these returns 0. Suites here run under `set -euo pipefail` and a
# reporter that can end the run it is reporting on would take the totals line
# down with it -- the one line that says how many failures there were.
nt_pass() {
    NT_PASSES=$((NT_PASSES + 1))
    echo "  PASS: $2"
    nt_row "$1" PASS "$2"
    return 0
}

nt_fail() {
    NT_FAILURES=$((NT_FAILURES + 1))
    echo "  FAIL: $2"
    nt_row "$1" FAIL "$2"
    # The GitHub annotation, which netinstall/test/lib.sh's own nt_fail carried
    # and which was never a netinstall property: a red check saying what went
    # wrong on the run page, without opening a log, is worth having on any lane
    # that asks for it.
    #
    # Opt-in, and that is the whole design. GitHub keeps thirty annotations per
    # job and drops the rest silently, oldest first -- which is why netinstall's
    # *readings* had to stop emitting them, six of seven lanes having been pinned
    # at exactly thirty. Failures are rare, so a failure can afford one; a
    # reporter that annotated by default would refill the bucket it emptied.
    [ -n "${NT_ANNOTATE:-}" ] && [ -n "${GITHUB_ACTIONS:-}" ] &&
        echo "::error title=$NT_ANNOTATE::$NT_SUITE: $2"
    return 0
}

# SKIP, which until now did not exist. sheet.sh has counted a skip column since
# it was written and two files in the whole tree ever filled it, so a lane that
# *cannot* run a check has been indistinguishable from one that did not -- and
# the exemptions that do exist are spelled as a lane name in an if, which says
# nothing to a reader of the run. A skip carries its reason for the same purpose
# a failure carries its detail.
nt_skip() {
    NT_SKIPS=$((NT_SKIPS + 1))
    echo "  SKIP: $2"
    nt_row "$1" SKIP "$2"
    return 0
}

# A measurement, never a verdict. It takes no case id because it is not a case:
# `report:` lines are the standing evidence a later round reads, and filing them
# as assertions would put readings in the cross-lane matrix, where every row is
# supposed to be something that can be true or false.
nt_report() { echo "report: $*"; return 0; }

# The two comparisons that account for most of the assertions in the tree.
#
# The spelling of the passing line is `name (value)` and of the failing one
# `name expected=… actual=…`, which is what assemble.sh's eq() has always
# printed and what most of the suites copied from it.
nt_eq() {
    if [ "$3" = "$4" ]; then
        nt_pass "$1" "$2 ($3)"
    else
        nt_fail "$1" "$2 expected=$4 actual=$3"
    fi
}

nt_match() {
    case "$3" in
        $4) nt_pass "$1" "$2 ($3)" ;;
        *)  nt_fail "$1" "$2 did not match $4; actual=$3" ;;
    esac
}

# One ` key=value` field out of a report, and the most-copied line in the tree:
# twenty-three spellings of it across ten files, in three dialects.
#
#   [^ ]*      seventeen, in eight files
#   [0-9]*     four, in themeflip.sh and fontflip.sh, over a counter
#   [A-Za-z]*  three, in verify-attack.sh, verify-early.sh and navrefuse.sh
#
# Here rather than beside the window-title reader most of them serve, because
# lib/analyse.sh reads these out of a recorded page state and the two
# differentials out of a `report:` line -- the shape is a record, not a window
# -- and because a helper ten files want is one every file should already have
# when it sources the six words.
#
# The space before the key is what separates one field from the next, and every
# copy has it in the pattern: without it `nav` also matches the tail of
# `postnav`, and both of those sit in one title answering different questions.
# What only thirteen of the twenty-three have is the space *prepended to the
# subject*, and that is what lets the first field on a line match at all -- with
# the subject `at=held tx=none` and no leading space there is no ` at=` to find,
# and the key that is plainly there reads as absent. The other ten got away with
# it by never being handed a subject whose first token was the key.
#
# `[^ ]*` for all of them. The narrow classes silently truncate a value with a
# character they do not list, and a truncated reading compares unequal to itself
# without saying why. Nothing relied on the truncation: the fields the three
# `[A-Za-z]*` copies read are words, and the four `[0-9]*` ones read `n=`, which
# a probe writes as a counter followed by a space.
nt_field() { printf '%s' " $2" | sed -n "s/.* $1=\([^ ]*\).*/\1/p"; }

# The last line of a suite, and its exit status.
#
# The status is the count of failed cases. That contract predates this file --
# verify-std.sh has always exited its failure count and says so at length -- and
# test/run.sh relies on it to add a lane up without parsing anything.
#
# The totals line keeps the shape verify-std.sh established, with the two
# counters that were never there before. A caller that has its own arithmetic to
# do (decoflip adds its halves to its differential) reads $NT_FAILURES and calls
# nothing here.
nt_finish() {
    nt_report "totals ${NT_SUITE} passes=$NT_PASSES failures=$NT_FAILURES skips=$NT_SKIPS"
    exit "$NT_FAILURES"
}
