# title.sh - the window title, read the same way on every lane.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Sourced, never run, below the harness line:
#
#   . "$(dirname "$0")/lib/harness.sh"
#   . "$(dirname "$0")/lib/title.sh"
#
# Half of what this tree asserts arrives in a window title. The launcher's walk
# names eight states in one, the standards probes report their fields in one,
# and every live half here decides whether a watcher fired by reading one twice.
# So "what does the window say" is the most-copied question in test/, and until
# this file existed it was answered in five places:
#
#   verify-attack.sh  ^ATTACK        verify-early.sh  ^EARLY
#   demo.sh           ^DEMOPROBE     themeflip.sh     ^STD-LIVE
#   fontflip.sh       ^STD-LIVEFONT
#
# Five copies of one cascade -- xdotool where there is one, wmctrl where there
# is not -- differing in the prefix and in nothing else that was meant.
#
# ------------------------------------------------------- what they disagreed on
#
# `|| true`, and it is not cosmetic. Under `set -euo pipefail` an xdotool that
# finds nothing, or a wmctrl that cannot open the display, takes its pipeline
# non-zero, and `set -e` then ends the suite *inside its own wait loop* -- before
# the branch that exists to say the app never reported. The run stops after
# "Waiting for the attack app to report" with no verdict and no reason, which is
# the one outcome those files are written not to produce. verify-attack.sh
# carries the line and a paragraph about why; verify-early.sh copied both.
#
# The other three do not carry it, and they are right today for a reason none of
# them states: demo.sh, themeflip.sh and fontflip.sh run under `set -uo` with no
# `-e`. That is a property of a line at the top of a different file, one edit
# away from being false, and the failure it would produce is the silent one
# above. Carrying it here makes it unconditional and costs nothing where it was
# already unnecessary.
#
# ------------------------------------------------------------------- the reader
#
# Three, and which one this machine has is asked once at source time rather than
# per call. That is what the five copies did too -- each defined `read_title` in
# one branch of an `if` -- and the reason is the same: on the slowest lane a
# `command -v` per poll is a process per poll.
#
# `status` is macOS. There is no window a shell can query there, so every check
# reads the file the testing-tier driver writes; NT_STATUS_FILE is the harness's
# name for it.
#
# The machine is asked, and not the mode under test. themeflip.sh chose its
# reader off its `<gtk|qt|macos>` argument, which is which desktop knob is being
# flipped -- a different question that happens to give the same answer on every
# lane, because the macos knob is only ever flipped on macOS. Conflating the two
# is how a suite run by hand on a desk reads for a window server it does not
# have.

# Sourced by a file that already has the harness, or reached by one that does
# not. The guard is walk.sh's and analyse.sh's, for the reason those two give:
# sourcing harness.sh twice resets the counters a live verifier is part-way
# through filling. NT_STATUS_FILE below is the harness's, which is why this
# cannot simply assume it.
if ! command -v nt_pass >/dev/null 2>&1; then
    NT_TITLE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/harness.sh"
    # shellcheck source=/dev/null
    . "$NT_TITLE_LIB"
fi

if [ -z "${NT_TITLE_HOW:-}" ]; then
    if [ "$(uname -s)" = Darwin ]; then
        NT_TITLE_HOW=status
    elif command -v xdotool >/dev/null 2>&1; then
        NT_TITLE_HOW=xdotool
    elif command -v wmctrl >/dev/null 2>&1; then
        NT_TITLE_HOW=wmctrl
    else
        # Not an error here. A suite with no way to read a title has no question
        # it can answer, and what it owes the grid is a skip per case with this
        # as the reason -- which is a thing only the suite knows how to say.
        NT_TITLE_HOW=none
    fi
fi

# The title now, if it starts with $1, and nothing otherwise.
#
# All three readers anchor at the start of the title and always did: xdotool
# takes a regex, the wmctrl sed captures from the first column after the host
# field, and the status file is read a line at a time. Two of the five copies
# relied on that without saying it, and three re-tested the prefix in a `case`
# below the read; it is a contract here so that both spellings are right.
#
# The macOS branch was the one copy that did not filter -- it returned line one
# whatever was in it -- which is why those `case` lines existed at all. Same
# answer either way, and one less place to spell the prefix.
nt_title() {
    case "$NT_TITLE_HOW" in
        status)
            # Line one and then the prefix, in two processes rather than one
            # sed with a block in it: the file is eight lines -- title, then the
            # geometry every macOS check reads out of it -- so a pattern applied
            # to the whole of it could answer from a line that is not the title,
            # and `1{/^x/p;}` is the shape of sed script BSD sed has historically
            # been particular about. This runs at a poll interval, not in a loop
            # over a file list.
            sed -n '1p' "$NT_STATUS_FILE" 2>/dev/null | grep "^$1" || true
            ;;
        xdotool)
            local wid
            wid="$(xdotool search --name "^$1" 2>/dev/null | head -1)" || true
            [ -n "$wid" ] && xdotool getwindowname "$wid" 2>/dev/null || true
            ;;
        wmctrl)
            # wmctrl -l is `<id> <desktop> <host> <title>`, so three fields are
            # skipped and the capture begins exactly where the title does.
            wmctrl -l 2>/dev/null |
                sed -n "s/^[^ ]* *[^ ]* *[^ ]* *\($1.*\)\$/\1/p" | tail -1 || true
            ;;
    esac
}

# Whether a window carrying $1 is up *right now*, which is not the same question
# and is not answered by asking whether nt_title returned something.
#
# On X11 it is the server's answer about a window, before anybody asks that
# window its name -- a window that exists and whose getwindowname fails is still
# a window the next verifier would attach to, and that is the hazard.
#
# On macOS it has to be posed the other way round, and this is the part worth
# reading twice: the status file is not a window, it is a thing the app writes,
# and a dead app leaves its last line behind forever. So the file is removed and
# what is watched is whether it comes *back*. The ticker rewrites every 200ms,
# so a second is generous.
#
# That destroys the reading, which is why callers take it before a launch and
# never during one.
#
# All three copies of this asked xdotool whatever the machine had, so on a desk
# with wmctrl and no xdotool they answered "no window is up" by not being able
# to look. That is the dangerous direction for a precondition, and it is what
# the wmctrl branch is here to stop. With no reader at all the answer is still
# "no window is up", because there is nothing else it can be -- a suite that
# reaches this line with NT_TITLE_HOW=none has already lost the run.
nt_title_live() {
    case "$NT_TITLE_HOW" in
        status)
            rm -f "$NT_STATUS_FILE"
            sleep 1
            sed -n '1p' "$NT_STATUS_FILE" 2>/dev/null | grep -q "^$1"
            ;;
        xdotool)
            [ -n "$(xdotool search --name "^$1" 2>/dev/null | head -1)" ]
            ;;
        *)
            [ -n "$(nt_title "$1")" ]
            ;;
    esac
}

# The precondition two flips share: the previous half's window is off the
# screen, so the next half cannot read it and report about the wrong desktop.
#
# Both halves of a flip carry one prefix -- that is what makes them comparable
# -- and it is also what makes a survivor indistinguishable from a real reading.
# A whole round was once lost to a phase reading the previous phase's title.
#
# Thirty seconds either way. On X11 that is sixty polls half a second apart; on
# macOS nt_title_live sleeps a second of its own, so the count is the seconds.
nt_title_gone() {
    local n=0 limit=60
    [ "$NT_TITLE_HOW" = status ] && limit=30
    while [ "$n" -lt "$limit" ]; do
        nt_title_live "$1" || return 0
        n=$((n + 1))
        [ "$NT_TITLE_HOW" = status ] || sleep 0.5
    done
    return 1
}
