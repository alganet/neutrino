#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# annotate.sh - Carries a verifier's result out of a job log and into annotations.
#
# The webview lanes report to their job log, and reading a job log needs a token
# that whoever is looking at a failed run may not have -- the checks API serves
# annotations and nothing else. netinstall's suites already solved this for
# themselves with nt_result; these lanes had nothing, so a red webview lane said
# only that it was red. Now the report line that explains it comes out with it.
#
# Two things this has to respect. GitHub keeps ten annotations of each level per
# step and drops the rest silently, and a verifier's output is naturally more
# lines than that; so runs of identical lines collapse to a count and what is
# left is packed several to an annotation. And a step that produced nothing says
# so, because an empty result and a verifier that never ran look identical
# otherwise.
#
# Usage: annotate.sh <label> <logfile> [extended-regex]

set -uo pipefail

LABEL="${1:-probe}"
FILE="${2:-}"
PATTERN="${3:-report:|FAIL:}"
# Eight chunks of five is forty lines, and GitHub keeps ten annotations of each
# level per step -- so eight plus the "dropped" notice is the cap and the
# chunk size is the only thing left to turn. A step whose log has more to say
# than forty lines raises PER_CHUNK rather than losing its middle: an
# annotation carries kilobytes and the netbsd lane was dropping suite failures
# it had been added to report.
MAX_CHUNKS="${NT_ANNOTATE_CHUNKS:-8}"
PER_CHUNK="${NT_ANNOTATE_PER:-5}"

emit() {
    echo "$*"
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning title=$LABEL::$*"
    return 0
}

if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
    emit "no log at '${FILE:-<none>}' -- the step did not get as far as writing one"
    exit 0
fi

# -a because a webview's stderr is not promised to be text, and one stray byte
# makes grep call the whole file binary and print nothing at all.
LINES="$(grep -aE "$PATTERN" "$FILE" 2>/dev/null \
    | sed -e 's/^neutrino: //' -e 's/[[:cntrl:]]//g' -e 's/^[[:space:]]*//' \
    | uniq -c | sed -e 's/^ *1 //' -e 's/^ *\([0-9]*\) /[x\1] /')"

if [ -z "$LINES" ]; then
    emit "nothing matched /$PATTERN/ in $(basename "$FILE") ($(wc -l < "$FILE" | tr -d ' ') lines); tail: $(tail -c 300 "$FILE" | tr '\n' ' ' | tr -d '[:cntrl:]')"
    exit 0
fi

# Over the cap it is the middle that goes, not the tail. A trace's last lines
# are where the answer usually is -- the settled marks, the title that says the
# probe rendered at all -- and dropping from the end throws exactly those away.
printf '%s\n' "$LINES" | awk -v label="$LABEL" -v per="$PER_CHUNK" -v max="$MAX_CHUNKS" \
    -v ga="${GITHUB_ACTIONS:-}" '
    function say(text) { if (ga != "") print "::warning title=" label "::" text }
    function flush() {
        if (buf == "") return
        chunk[++chunks] = buf
        buf = ""
    }
    { buf = buf (buf == "" ? "" : " | ") $0; if (++n % per == 0) flush() }
    END {
        flush()
        if (chunks <= max) {
            for (i = 1; i <= chunks; i++) say(i ") " chunk[i])
            exit
        }
        head = int(max / 2)
        tail = max - head - 1
        for (i = 1; i <= head; i++) say(i ") " chunk[i])
        say((chunks - head - tail) " chunk(s) dropped from the middle at the annotation cap")
        for (i = chunks - tail + 1; i <= chunks; i++) say(i ") " chunk[i])
    }
'

# The same content unpacked, for whoever can read the log.
printf '%s\n' "$LINES" | sed "s/^/[$LABEL] /"
exit 0
