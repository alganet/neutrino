# analyse.sh - what the standards probes recorded, and whether it holds.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Usage, standalone:  bash test/lib/analyse.sh <probe> <record.tsv>
#        or sourced:  . test/lib/analyse.sh   then   nt_analyse <probe>
#
# These assertions were written twice. verify-std.sh had analyse_geom, _doc,
# _win, _theme and _font and check_apparatus; verify-std.ps1 had Analyse-Geom,
# -Doc, -Win, -Theme, -Font and Check-Apparatus, one for one, over a record with
# the same columns -- and the two files cross-referenced each other six times
# asking a reader to keep them in step. verify-std.sh:567 carried a check it
# said was "a no-op here ... written anyway so the two files cannot drift into
# measuring different sets of rows", which is deliberately dead code kept for
# symmetry, which is the cost of the arrangement stated out loud.
#
# What is genuinely per-platform is the *instrument*: xdotool on X11, a status
# file on macOS, GetWindowRect on Win32. What reads the record it produced is
# not, and this is that half, in one copy.
#
# It runs on every lane because bash does. That is not a new bet -- decoflip.ps1
# already ends by calling `bash test/decodiff.sh` and adding its exit status,
# and sheet.sh has been the one reporting tool on all of them since it was
# written. Measured before it was moved: the five records verify-std.ps1
# sampled on windows-content, replayed through these functions, produce the same
# control verdicts the PowerShell analysers produced from them, on all five
# probes.
#
# ------------------------------------------------------------------ its inputs
#
# The record, and what the apparatus was. Everything here reads $REC and the
# scalars below and touches nothing else -- no window, no display, no clock --
# which is what lets `verify-std.sh <probe> <dir> <record>` replay a run with
# none of them present, and what lets the Windows lane hand its record over.
# harness.sh for nt_row alone. Its nt_pass/nt_fail are not used here: this file
# keeps verify-std.sh's `fail` and `note` spellings so the prose is unchanged,
# and only borrows the row writer. Guarded, because verify-std.sh may have
# sourced it already.
if ! command -v nt_row >/dev/null 2>&1; then
    NT_HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/harness.sh"
    # shellcheck source=/dev/null
    [ -f "$NT_HARNESS" ] && . "$NT_HARNESS"
fi

REC="${REC:-}"
PROBE="${PROBE:-}"
PLATFORM="${PLATFORM:-x11}"
PREFIX="${PREFIX:-}"
DWELL="${DWELL:-1500}"
IDLE_LIMIT="${IDLE_LIMIT:-22}"
TURNS="${TURNS:-0}"

# Set by the sampling loop, which is the only place they can be set: the record
# holds transitions and transitions are a dwell apart on purpose, so nothing
# after the loop can reconstruct the interval between two consecutive polls.
# A replay has no loop and says so rather than reporting a number it never took.
MAX_TURN_GAP="${MAX_TURN_GAP:--1}"
STOPPED_BY="${STOPPED_BY:-deadline}"

# The X11 apparatus, when there was one.
FE_L="${FE_L:-0}"; FE_R="${FE_R:-0}"; FE_T="${FE_T:-0}"; FE_B="${FE_B:-0}"
FE_SRC="${FE_SRC:-?}"
REL_SRC="${REL_SRC:-none}"
XW_ABS="${XW_ABS:-?}"; XD_ABS="${XD_ABS:-?}"; XW_REL="${XW_REL:-?}"
X11_WID="${X11_WID:-}"; X11_SRC="${X11_SRC:-?}"

# The reporter. verify-std.sh defines these before sourcing this file and keeps
# its own; a standalone run gets the same two spellings, so a record analysed
# either way produces the same lines.
if ! command -v fail >/dev/null 2>&1; then
    FAILURES=0
    fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
    note() { echo "report: $*"; }
fi

# ------------------------------------------------------------------- controls
#
# A control is the thing a probe exists to establish, and it has two branches:
# it held, or it did not. Until now only one of those said anything a reader
# could count. A green standards run emits *no* PASS line at all -- successes
# are `report: control ... verdict=AGREED`, failures are `FAIL:` -- so from
# outside, a control that held and a control that was never reached looked the
# same, and neither reached the digest.
#
# These three print exactly what `note` and `fail` printed, so every line this
# file has ever emitted is unchanged and the record replays byte for byte. What
# they add is the row: a case id, and a verdict that exists in all three states.
#
# ctl_skip is the one that could not be said before. `not_asked` and the named
# `KNOWN` exemptions are lanes where the question does not apply -- an engine
# whose system-font keywords are not the desktop's cannot be asked whether they
# agree with it -- and they were reported as readings, which is to say as
# nothing. A skip is a lane saying why it is not answering.
nt_ctl_row() {
    command -v nt_row >/dev/null 2>&1 || return 0
    nt_row "$1" "$2" "$3"
}
ctl_pass() { note "$2"; nt_ctl_row "$1" PASS "$2"; }
ctl_fail() { fail "$2"; nt_ctl_row "$1" FAIL "$2"; }
ctl_skip() { note "$2"; nt_ctl_row "$1" SKIP "$2"; }

# Every distinct title the loop saw, in order, with what was measured beside it.
field() { awk -F'\t' -v n="$1" -v want="$2" '$2 ~ want { print $n; exit }' "$REC"; }
# State names only. The full titles are in the record dumped at the end; a
# sequence line that repeats a whole -SELF payload says twice what the self line
# beside it already said once.
titles() { awk -F'\t' '{ print $2 }' "$REC" | awk '{ print $1 }' | tr '\n' ' '; }

# ------------------------------------------------------------------ assertions

check_apparatus() {
    local rows gap
    rows="$(wc -l < "$REC" | tr -d ' ')"
    gap="$MAX_TURN_GAP"
    note "sampler platform=$PLATFORM turns=${TURNS:-0} transitions=$rows dwell_ms=$DWELL max_turn_gap_ms=$gap stopped_by=$STOPPED_BY idle_limit_s=$IDLE_LIMIT"
    if [ "$PLATFORM" = x11 ]; then
        note "sampler frame_extents l=$FE_L r=$FE_R t=$FE_T b=$FE_B wid=$X11_WID via=$X11_SRC"
        # Two routes to the *client* corner, printed beside each other so the
        # subtraction the loop makes can be checked rather than trusted:
        # xwininfo's absolute upper-left is that corner directly, and xdotool's
        # Position is the same corner with the reparenting offset added to it.
        # They agreeing is what says `xdotool minus rel` is sound -- which is
        # all it ever said. It is not a frame origin and calling it one is what
        # let this file report a client corner as a frame for three rounds; the
        # frame is that corner minus the decoration, and the line below prints
        # both so neither can stand in for the other again.
        local client="" framed=""
        case "$XD_ABS" in
            *[0-9]*,*[0-9]*) client="$(( ${XD_ABS%%,*} - REL_X )),$(( ${XD_ABS##*,} - REL_Y ))" ;;
        esac
        case "$client" in
            *[0-9]*,*[0-9]*) framed="$(( ${client%%,*} - FE_L )),$(( ${client##*,} - FE_T ))" ;;
        esac
        note "sampler origin rel=${XW_REL:-?} src=$REL_SRC xwininfo_abs=${XW_ABS:-?} xdotool_abs=${XD_ABS:-?} client=${client:-?} frame=${framed:-?}"
        if [ -n "$XW_ABS" ] && [ -n "$client" ] && [ "$XW_ABS" != "$client" ]; then
            fail "the client corner differs by route (xwininfo says $XW_ABS, xdotool minus rel says $client); every position below is the second route"
        fi
        if [ "$REL_SRC" = none ]; then
            note "sampler no reparent offset available; positions are raw and underived"
        fi
    fi
    # The decoration, named. It is a difference between two columns this file
    # has recorded on every lane since it was written, and until now nothing
    # said so out loud -- which is how a fifty-pixel tolerance in the suite next
    # door went on standing in for a number that was already being measured
    # three feet away.
    #
    # Every distinct value across the run, not the first: a thickness that
    # changed while the window was up is a finding, and printing one value would
    # hide it. On x11 the pair below has to be read with `via=`, because there
    # the outer column is derived from a hint read once and a zero extent can
    # mean the hint said zero or that nothing answered at all.
    # Only the rows the app had arrived in -- the same gate verify-std.ps1
    # applies, and one rule rather than two. It is a no-op here, because this
    # side finds its window by the prefix and so never records a turn before
    # it; it is written anyway so the two files cannot drift into measuring
    # different sets of rows.
    local extents
    extents="$(awk -F'\t' -v pre="$PREFIX" '
        index($2, pre) != 1 { next }
        $3 ~ /^[0-9]+x[0-9]+$/ && $5 ~ /^[0-9]+x[0-9]+$/ {
            split($3, i, "x"); split($5, o, "x")
            e = (o[1] - i[1]) "x" (o[2] - i[2])
            if (!(e in seen)) { seen[e] = 1; out = out (out == "" ? "" : " ") e }
        }
        END { print out }
    ' "$REC")"
    if [ "$PLATFORM" = x11 ]; then
        note "sampler extent ${extents:-none} via=$FE_SRC"
    else
        note "sampler extent ${extents:-none} via=live"
    fi
    # The frame origin at the probe's *first* state, under one name both
    # platforms emit, so the differential has a position to compare without
    # knowing which instrument took it. It is a frame on all three of them as
    # of this round: macOS reports one, Windows reports one, and x11 now takes
    # the decoration off the client corner instead of handing decodiff.sh a
    # client corner named `framepos`.
    #
    # The first state and not the last, because the probe moves the window on
    # purpose partway through: the only turn where the two halves are answering
    # the same question is the one before either of them was asked to move.
    local firstpos
    firstpos="$(awk -F'\t' -v pre="$PREFIX" 'index($2, pre) == 1 { print $4; exit }' "$REC")"
    note "sampler framepos ${firstpos:-none}"
    if [ "$rows" -lt 2 ]; then
        fail "the instrument recorded $rows transition(s); it saw no window change at all"
    fi
    # The one failure mode this branch has already paid for. On the macOS
    # bridge, String() of an ObjC wrapper is its description and not its
    # contents, so a title read the wrong way arrives as `[id __NSCFString]`.
    # It costs one line to name, and without it the symptom is five suites
    # timing out on a channel that looks like it is being written normally.
    if grep -q "$(printf '\t')\[id " "$REC"; then
        fail "a recorded title is an ObjC wrapper's description, not a title; something wrote it without unwrapping"
    fi
    if [ "$gap" = "-1" ]; then
        note "sampler no millisecond clock here; the completeness of the record below is the control"
    elif [ "$gap" -ge "$DWELL" ]; then
        fail "the slowest turn was ${gap}ms against a ${DWELL}ms dwell; this run sampled, it did not watch"
    fi
}

analyse_geom() {
    local a b c r
    a="$(field 2 '^STD-GEOM-A-PAIR')"
    b="$(field 2 '^STD-GEOM-B-PAIR')"
    c="$(field 2 '^STD-GEOM-C-PAIR')"
    r="$(field 2 '^STD-GEOM-R-SELF')"

    local ai ao ap bi bo bp ci co cp
    ai="$(field 3 '^STD-GEOM-A-PAIR')"; ao="$(field 5 '^STD-GEOM-A-PAIR')"; ap="$(field 4 '^STD-GEOM-A-PAIR')"
    bi="$(field 3 '^STD-GEOM-B-PAIR')"; bo="$(field 5 '^STD-GEOM-B-PAIR')"; bp="$(field 4 '^STD-GEOM-B-PAIR')"
    ci="$(field 3 '^STD-GEOM-C-PAIR')"; co="$(field 5 '^STD-GEOM-C-PAIR')"; cp="$(field 4 '^STD-GEOM-C-PAIR')"

    [ -n "$a" ] || fail "STD-GEOM-A-PAIR was never observed"
    [ -n "$b" ] || fail "STD-GEOM-B-PAIR was never observed"
    [ -n "$c" ] || fail "STD-GEOM-C-PAIR was never observed"

    local ar br cr
    ar="$(field 7 '^STD-GEOM-A-PAIR')"; br="$(field 7 '^STD-GEOM-B-PAIR')"; cr="$(field 7 '^STD-GEOM-C-PAIR')"
    [ -n "$a" ] && note "pair A page=[${a#STD-GEOM-A-PAIR }] native inner=$ai outer=$ao pos=$ap raw=$ar"
    [ -n "$b" ] && note "pair B page=[${b#STD-GEOM-B-PAIR }] native inner=$bi outer=$bo pos=$bp raw=$br"
    [ -n "$c" ] && note "pair C page=[${c#STD-GEOM-C-PAIR }] native inner=$ci outer=$co pos=$cp raw=$cr"
    [ -n "$r" ] && note "self ${r#STD-GEOM-R-SELF }"

    # The one -SELF reading in this file that is asserted, and the exception
    # earns its lines. The rule everywhere else is that a document's account of
    # itself is a diagnostic and the instrument outside it is the reading --
    # sound, because the window is the thing in question and the page's view of
    # it can be wrong. Here the question is whether the API was in scope when
    # the app's own first statement ran, and no instrument outside the document
    # can see that. The page is not the best witness, it is the only one.
    #
    # Asserted rather than printed because `pages/demo.js` stopped polling for
    # the API on the strength of it, and a guarantee nothing checks is a
    # comment. A lane that starts registering the API later fails here instead
    # of in the sample app, which nothing in CI builds.
    case "$r" in
        "")        ctl_fail std.geom.api-in-scope "control STD-GEOM-R-SELF was never observed; readiness went unmeasured this run" ;;
        *nt0=yes*) ctl_pass std.geom.api-in-scope "control the API was in scope at the app's first statement (nt0=yes)" ;;
        *)         ctl_fail std.geom.api-in-scope "control nt0=$(printf '%s' "$r" | sed -n 's/.*nt0=\([^ ]*\).*/\1/p'); window.neutrino was not in scope at the app's first statement, and pages/demo.js no longer waits for it" ;;
    esac

    # The number four drivers have been disagreeing about. resize(640,480) means
    # ClientSize on Windows, the outer frame on macOS and the toplevel size on
    # the two GTK lanes; verify-linux.sh has been hiding the difference behind a
    # fifty-pixel tolerance since it was written.
    if [ -n "$bi" ] && [ -n "$bo" ]; then
        note "sizing req=640x480 native_inner=$bi native_outer=$bo"
    fi
    if [ -n "$cp" ]; then
        note "moving req=120,90 native_frame=$cp native_raw=$cr rel=${XW_REL:-?} extents=l$FE_L,t$FE_T"
    fi

    # The positive control, and the reason the two mutations above go through the
    # API that already works. Every "the page's number is wrong" reading in this
    # file is unattributable without it: a window that never moved and an
    # instrument pointed at the wrong one produce identical readings.
    if [ -n "$ai" ] && [ -n "$bi" ] && [ "$ai" != "$bi" ]; then
        ctl_pass std.geom.resize "control resize A->B inner $ai -> $bi verdict=MOVED"
    else
        ctl_fail std.geom.resize "control resize A->B inner $ai -> $bi; the instrument saw no size change"
    fi
    if [ -n "$bp" ] && [ -n "$cp" ] && [ "$bp" != "$cp" ]; then
        ctl_pass std.geom.move "control move B->C pos $bp -> $cp verdict=MOVED"
    else
        ctl_fail std.geom.move "control move B->C pos $bp -> $cp; the instrument saw no position change"
    fi
}

analyse_doc() {
    local ctl end rb dom1 dom2 after opened
    ctl="$(field 2 '^STD-DOC-CTL')"
    end="$(field 2 '^STD-DOC-END')"
    rb="$(field 2 '^STD-DOC-RB-SELF')"
    dom1="$(field 2 '^STD-DOC-DOM1')"
    dom2="$(field 2 '^STD-DOC-DOM2')"

    note "doc sequence: $(titles)"
    [ -n "$rb" ] && note "self ${rb#STD-DOC-RB-SELF }"

    # The early shell, asked for at the app's first statement.
    #
    # An app's markup is included into the document by the assembler so that it
    # is in the first paint, and the whole point of that is an app that can read
    # it. Four lanes get that from their engine and Windows did not: its one
    # pre-navigation hook runs before the parser has produced anything, so
    # getElementById answered null on the first line and an app written the way
    # the other four allow failed silently there. It shipped in the sample app on
    # the download page, where the Close button did nothing on Windows. So this
    # is an assertion on every lane and not a note -- including the four that
    # have always kept it, because a promise only one verifier checks is a
    # promise the other lanes can lose quietly.
    local body0
    body0="$(nt_field body0 "$rb")"
    if [ "$body0" = "yes" ]; then
        ctl_pass std.doc.early-shell "control the early shell was on the page at the app's first statement (body0=yes)"
    else
        ctl_fail std.doc.early-shell "control body0=${body0:-<absent>}; document.body was not there when the app's first statement ran, so an app cannot read its own markup on this lane"
    fi

    # The name the window came up wearing, before the app wrote anything. The
    # launcher puts the build's title into the document, so this is also the
    # first title-changed signal of the launch and it has to be a no-op. A note
    # and not an assertion: this loop starts when the window appears, and a lane
    # that is slow to hand the recorder its first read would be reporting its
    # own scheduling.
    opened="$(awk -F'\t' 'NR == 1 { print $2; exit }' "$REC")"
    note "opened native=[${opened:-<nothing recorded>}]"

    # The change this suite exists for. Both writes are plain assignments to
    # document.title and both have to reach the native window; a lane where they
    # do not is a lane whose title hook is not connected, which is the whole of
    # the finding.
    if [ -n "$dom1" ]; then note "pair dom1 native=seen"; else fail "pair dom1 native=absent; an assignment to document.title did not reach the window"; fi
    if [ -n "$dom2" ]; then note "pair dom2 native=seen"; else fail "pair dom2 native=absent; an assignment to document.title did not reach the window"; fi

    # And the two the gate refuses, asked as one question: what the window was
    # showing after them. DOM2 is the last title that may reach it, so the next
    # recorded state has to be the report at the end of the sequence. An empty
    # title reaching the window would take the app's name away; a marked one
    # reaching it would put a record in the channel every verifier here reads.
    after="$(awk -F'\t' '/STD-DOC-DOM2/ { found=1; next } found { print $2; exit }' "$REC")"
    if [ -z "$dom2" ]; then
        note "pair refused not_asked: no DOM write reached the window to hold"
    else
        case "$after" in
            "STD-DOC-RB-SELF"*)
                note "pair refused after_dom2_native=[held DOM2 through both]" ;;
            "")
                fail "pair refused after_dom2_native=[nothing recorded]; the sequence stopped at DOM2" ;;
            *)
                fail "pair refused after_dom2_native=[$after]; the window took a title the gate refuses" ;;
        esac
    fi

    # The brackets. A run where the hook did nothing and a run where no window
    # ever came up are the same empty reading without them.
    if [ -n "$ctl" ]; then ctl_pass std.doc.ctl-observed "control ctl observed=YES"; else ctl_fail std.doc.ctl-observed "control ctl was never observed; the instrument read no window"; fi
    if [ -n "$end" ]; then ctl_pass std.doc.end-observed "control end observed=YES"; else ctl_fail std.doc.end-observed "control end was never observed; the app did not finish its sequence"; fi
}

# The row before a named one. Every native-call verdict below is a comparison
# against the state immediately preceding it, not against the window's opening
# geometry -- four calls in a row each need their own before-picture, and the
# one the last call left is it.
prev_field() { awk -F'\t' -v n="$1" -v want="$2" '$2 ~ want { print p; exit } { p = $n }' "$REC"; }

# What one native call did, said in the two words that matter. "The call
# returned without throwing" is the page's half and is already in the title;
# this is the other one.
verdict() {
    local before="$1" after="$2"
    if [ -z "$after" ]; then echo "UNOBSERVED"
    elif [ "$before" = "$after" ]; then echo "NOOP"
    else echo "EFFECTIVE"; fi
}

analyse_win() {
    local st page inner pos pinner ppos v moved_any on ov
    note "win sequence: $(titles)"

    for st in EXIST DESC OVR OPEN APPREGION GONE; do
        page="$(field 2 "^STD-WIN-$st-SELF")"
        [ -n "$page" ] && note "self $st ${page#STD-WIN-$st-SELF }"
    done

    # window.open, and the one shape of it the page can answer for.
    #
    # What an external url does is not askable from inside the document: it
    # becomes a record, the host decides, and the desktop's URI handler acts.
    # parse.sh asserts that half against the built preload with no engine. What
    # is here is the no-argument call, which the launcher answers itself -- the
    # platform's reply is a new about:blank window and this file does nothing
    # until there is a second window to open. QtWebEngine's own `open` returns
    # an object, so on that lane this is the difference between the launcher's
    # no-op and the engine's answer.
    #
    # And every shape must leave the document where it was. No url in the phase
    # can reach a browser, so a CHANGED here is this window having been
    # navigated away by a call that was meant to open a different one.
    page="$(field 2 '^STD-WIN-OPEN-SELF')"
    if [ -z "$page" ]; then
        ctl_fail std.win.open-noargs "control open: STD-WIN-OPEN-SELF was never observed"
    else
        on="$(nt_field noargs "$page")"
        case "$on" in
            null/same) ctl_pass std.win.open-noargs "control open noargs=$on verdict=NOOP" ;;
            "")        ctl_fail std.win.open-noargs "control open: STD-WIN-OPEN-SELF carried no noargs reading" ;;
            *)         ctl_fail std.win.open-noargs "control open noargs=$on, wanted null/same; window.open() is not the launcher's on this lane" ;;
        esac
        for v in blank self; do
            ov="$(nt_field "$v" "$page")"
            case "$ov" in
                */CHANGED) ctl_fail "std.win.open-target.$v" "control open $v=$ov; a call meant to open a window took this document somewhere" ;;
                "")        : ;;
                *)         ctl_pass "std.win.open-target.$v" "control open $v=$ov (the engine's own, left alone)" ;;
            esac
        done
    fi

    # The four. Each prints what the page said, what the window did, and the
    # word that separates a refusal from a no-op -- which are the same reading
    # from inside the document and different ones from out here.
    #
    # Before the launcher wrote over these, all four read NOOP on all four
    # engines. They are the shipped API now, so a NOOP here is a regression and
    # the control below says so.
    moved_any=0
    for st in RT RZ MT MV; do
        page="$(field 2 "^STD-WIN-$st-PAIR")"
        if [ -z "$page" ]; then
            fail "STD-WIN-$st-PAIR was never observed"
            continue
        fi
        inner="$(field 3 "^STD-WIN-$st-PAIR")"; pos="$(field 4 "^STD-WIN-$st-PAIR")"
        pinner="$(prev_field 3 "^STD-WIN-$st-PAIR")"; ppos="$(prev_field 4 "^STD-WIN-$st-PAIR")"
        case "$st" in
            RT|RZ) v="$(verdict "$pinner" "$inner")" ;;
            *)     v="$(verdict "$ppos" "$pos")" ;;
        esac
        [ "$v" = EFFECTIVE ] && moved_any=$((moved_any + 1))
        note "pair $st page=[${page#STD-WIN-$st-PAIR }] native $pinner@$ppos -> $inner@$pos verdict=$v"
    done

    page="$(field 2 '^STD-WIN-FS1-PAIR')"
    if [ -n "$page" ]; then
        inner="$(field 3 '^STD-WIN-FS1-PAIR')"; pinner="$(prev_field 3 '^STD-WIN-FS1-PAIR')"
        note "pair FS1 page=[${page#STD-WIN-FS1-PAIR }] native $pinner -> $inner verdict=$(verdict "$pinner" "$inner")"
    else
        fail "STD-WIN-FS1-PAIR was never observed"
    fi

    # close is the one phase whose answer is an absence. The page's `closed`
    # flag is its own account and the engine may set it optimistically; what
    # says the window went is the record ending, and the two are printed side
    # by side rather than one standing in for the other.
    #
    # STILL_UP is a failure and used to be a note. The probe waits 1200 ms after
    # the call before it writes STD-WIN-END, so a title that arrives is a window
    # that was still there more than a second after being told to go -- not a
    # race, and not something a slow lane produces. It was a note while nothing
    # had ever been seen to survive the call, and what that cost is the reading
    # nobody took: close() is in the README as one of the six verbs an app drives
    # its window with, and a lane where it did nothing would have passed green.
    page="$(field 2 '^STD-WIN-END')"
    if [ -n "$(field 2 '^STD-WIN-CLOSE-PAIR')" ]; then
        if [ -n "$page" ]; then
            fail "pair CLOSE page=[${page#STD-WIN-END }] native=STILL_UP; the window was still up 1200ms after close() and reported through itself to say so"
        else
            note "pair CLOSE page=[no title after the call] native=GONE"
        fi
    else
        fail "STD-WIN-CLOSE-PAIR was never observed"
    fi

    # Control one, and it moved with the thing it is about. It used to be a
    # separate call known to work -- `neutrino.window.resize`, which no longer
    # exists -- there to tell "the engine refused" from "the window is dead".
    # Those are now one call, so the question is asked of it directly: a run in
    # which none of the four moved the window is a dead window or an override
    # that did not take, and both are regressions rather than readings.
    if [ "${moved_any:-0}" -gt 0 ]; then
        ctl_pass std.win.verbs-move "control the standard spellings move the window: $moved_any/4 EFFECTIVE"
    else
        ctl_fail std.win.verbs-move "control none of resizeTo/resizeBy/moveTo/moveBy moved the window; either the override did not take or the window is dead, and this run measured neither"
    fi

    # Control two: the descriptors mean something. A reader that answers the
    # same for a property this file defined and for one the spec makes
    # unforgeable is a reader whose every other answer is void.
    page="$(field 2 '^STD-WIN-DESC-SELF')"
    local own forged
    own="$(printf '%s' "$page" | sed -n 's/.*CTLown=\([^ ]*\).*/\1/p')"
    forged="$(printf '%s' "$page" | sed -n 's/.*CTLforged=\([^ ]*\).*/\1/p')"
    if [ -n "$own" ] && [ -n "$forged" ] && [ "$own" != "$forged" ]; then
        ctl_pass std.win.descriptors "control descriptors own=$own forged=$forged verdict=DISTINGUISHED"
    else
        ctl_fail std.win.descriptors "control descriptors own=${own:-<none>} forged=${forged:-<none>}; the reader cannot tell them apart"
    fi
}

analyse_theme() {
    local a b v pp f fbv cav mqv scv srv
    note "theme sequence: $(titles)"
    a="$(field 2 '^STD-THEME-A-SELF')"
    b="$(field 2 '^STD-THEME-B-SELF')"
    v="$(field 2 '^STD-THEME-V-SELF')"
    pp="$(field 2 '^STD-THEME-P-SELF')"
    f="$(field 2 '^STD-THEME-F-SELF')"

    [ -n "$a" ] && note "self palette ${a#STD-THEME-A-SELF }"
    [ -n "$b" ] && note "self cssnames ${b#STD-THEME-B-SELF }"
    [ -n "$v" ] && note "self delivery ${v#STD-THEME-V-SELF }"
    [ -n "$pp" ] && note "self customprops ${pp#STD-THEME-P-SELF }"
    [ -n "$f" ] && note "self fonts ${f#STD-THEME-F-SELF }"

    # Everything this probe reports is the document's own account -- there is
    # no window property that carries a computed colour, so there is no outside
    # half to pair with and none is pretended. What keeps it from being a page
    # marking its own homework is the two controls below and, in the round
    # after this, a second launch with the desktop's palette flipped: a value
    # that moves with the desktop is the desktop's, and one that does not is
    # the engine's. One launch cannot tell those apart and does not claim to.
    case "$a" in
        *nsrc=null*) ctl_fail std.theme.palette-read "control palette: this lane read no toolkit, so every comparison here is void" ;;
        *nsrc=*)     ctl_pass std.theme.palette-read "control palette read=YES" ;;
        *)           ctl_fail std.theme.palette-read "control palette: STD-THEME-A-SELF was never observed" ;;
    esac

    # The scheme, read twice on one launch: `prefers-color-scheme` is the
    # engine's answer and `neutrino.theme.scheme` is the launcher's, taken from
    # the luminance of the palette the toolkit actually handed over. An app is
    # entitled to branch on either -- 3a gave it `var(--neutrino-Canvas)` beside
    # the media query it already had -- and a desktop where the two disagree is
    # one where it gets a dark palette under a light media query.
    #
    # One launch is enough for this one, unlike every colour above it. The two
    # readings come from different places in the same instant, so a disagreement
    # is a disagreement; there is no constant here that could be agreeing by
    # accident, because neither side is a constant.
    #
    # An engine with no matchMedia, or one that matches neither, is not asked.
    # There is nothing to disagree with and nothing to force, and saying so with
    # the value in it is what keeps this from going quiet on a lane that stopped
    # answering.
    # One lane is exempt, by name, with a reason and a way out. QtWebEngine does
    # not follow the toolkit palette here: measured across the flip, Qt's
    # palette moved efefef -> 323232 with the knob read back on both halves and
    # the query stayed light. It is the same defect the GTK lanes have and there
    # is nothing to set -- `QStyleHints::colorScheme` is readable from Qt 6.5
    # and settable from 6.8, and the runner this lane exists on is 6.4.2. A knob
    # written for a version nothing here can run is a guarantee about an API and
    # not about a document, which is how the last three rounds went wrong.
    #
    # So it is a note, and the note is the record: it prints the disagreement in
    # full every run rather than going quiet, and it says what retires it. This
    # is not a widened tolerance -- the exemption is one named toolkit, the other
    # five lanes still fail, and a `qt` that starts agreeing is told to come back
    # and delete this.
    #
    # Keyed on `nsrc`, the launcher's own answer about which toolkit it read,
    # and not on the engine string: the engine is what the page can see and the
    # source is what the reading came from.
    #
    # Nothing is said on the agreeing path about the exemption, and that is a
    # correction this file needed before it shipped: a light runner agrees
    # trivially -- both readings are "light" because there is nothing to be
    # wrong about -- so a `qt` lane here would have printed "the exemption is no
    # longer needed" on every green run it ever had. Agreement is only evidence
    # where the desktop was dark, and the only place that knows a desktop went
    # dark is themediff.sh, which is where that note lives.
    mqv="$(echo "$a" | sed -n 's/.*mq=\([^ ]*\).*/\1/p')"
    scv="$(echo "$a" | sed -n 's/.*nscheme=\([^ ]*\).*/\1/p')"
    srv="$(echo "$a" | sed -n 's/.*nsrc=\([^ ]*\).*/\1/p')"
    if [ -z "$mqv" ] || [ "$scv" = null ]; then
        :
    elif [ "$mqv" = unsupported ] || [ "$mqv" = threw ] || [ "$mqv" = none ]; then
        ctl_skip std.theme.scheme "control scheme not_asked mq=$mqv; this engine states no preference"
    elif [ "$mqv" = "$scv" ]; then
        ctl_pass std.theme.scheme "control scheme mq=$mqv neutrino=$scv verdict=AGREED"
    elif [ "$srv" = qt ]; then
        ctl_skip std.theme.scheme "control scheme KNOWN qt mq=$mqv against neutrino=$scv; QtWebEngine does not follow the toolkit palette and QStyleHints::colorScheme is Qt 6.8+, so this lane has no knob -- delete this exemption when a runner has one"
    else
        ctl_fail std.theme.scheme "control scheme mq=$mqv against neutrino=$scv; the page's media query and the palette it was handed disagree about this desktop"
    fi

    case "$b" in
        *control=UNSUP*) ctl_pass std.theme.unknown-keyword "control unknown-keyword=UNSUP verdict=DISTINGUISHED" ;;
        *control=*)      ctl_fail std.theme.unknown-keyword "control unknown-keyword resolved to a colour; every UNSUP below it is the instrument, not the engine" ;;
        *)               ctl_fail std.theme.unknown-keyword "control unknown-keyword: STD-THEME-B-SELF was never observed" ;;
    esac
    # The delivery. Two page readings, and the assertion is that they agree:
    # the palette an app gets from `neutrino.theme` came through the preload,
    # and the palette it gets from `var(--neutrino-Canvas)` came through a
    # stylesheet the launcher put in the document. Different mechanisms, one
    # measurement, and an app is entitled to either.
    case "$v" in
        *" match=7/7 "*) ctl_pass std.theme.delivery "control delivery match=7/7 verdict=DELIVERED" ;;
        *" pal=null "*)  ctl_skip std.theme.delivery "control delivery not_asked: this lane read no toolkit" ;;
        *match=*)        ctl_fail std.theme.delivery "control delivery ${v#*match=}; the properties and neutrino.theme disagree" ;;
        *)               ctl_fail std.theme.delivery "control delivery: STD-THEME-V-SELF was never observed" ;;
    esac

    # And the reason the properties are named for the keywords. A name the
    # launcher never sets has to fall through to the engine's own system
    # colour; a keyword the engine cannot resolve would leave the declaration
    # alone instead, and the page would style itself from whatever it inherited.
    fbv="$(nt_field fallback "$v")"
    cav="$(nt_field canvas "$v")"
    if [ -z "$fbv" ]; then
        :
    elif [ "$fbv" = "$cav" ] && [ "$fbv" != "UNSUP" ] && [ "$fbv" != "threw" ]; then
        ctl_pass std.theme.fallback "control fallback var(--neutrino-absent, Canvas)=$fbv Canvas=$cav verdict=RESOLVED"
    else
        ctl_fail std.theme.fallback "control fallback var(--neutrino-absent, Canvas)=$fbv against Canvas=$cav; an absent property does not reach the engine's own colour on this lane"
    fi

    if [ -n "$(field 2 '^STD-THEME-CTL')" ]; then
        ctl_pass std.theme.ctl-observed "control ctl observed=YES"
    else
        ctl_fail std.theme.ctl-observed "control ctl was never observed; the instrument read no window"
    fi
    if [ -n "$(field 2 '^STD-THEME-END')" ]; then
        ctl_pass std.theme.end-observed "control end observed=YES"
    else
        ctl_fail std.theme.end-observed "control end was never observed; the app did not finish its sequence"
    fi
}

# The engine half of the fonts delivery.
#
# Five controls, mirroring analyse_theme's six one for one: the lane read a
# toolkit, the two deliveries agree, an unset property reaches its generic, the
# launcher and the engine read the same desktop the same way, and the probe ran
# to the end.
#
# The keyword and generic readings it prints are reports and stay that way. They
# are the standing evidence for why the delivery is spelled with a separate
# `generic` field -- `system-ui` resolves on one WebKit and not the other -- and
# asserting them would fail a lane for a fact about its engine.
analyse_font() {
    local ctl kwa kwb gen unit nta ntb
    note "font sequence: $(titles)"
    ctl="$(field 2 '^STD-FONT-CTL')"
    kwa="$(field 2 '^STD-FONT-KW-A')"
    kwb="$(field 2 '^STD-FONT-KW-B')"
    gen="$(field 2 '^STD-FONT-GEN')"
    unit="$(field 2 '^STD-FONT-UNIT')"
    nta="$(field 2 '^STD-FONT-NT-A')"
    ntb="$(field 2 '^STD-FONT-NT-B')"

    [ -n "$ctl" ]  && note "self engine ${ctl#STD-FONT-CTL }"
    [ -n "$kwa" ]  && note "self keywords-a ${kwa#STD-FONT-KW-A }"
    [ -n "$kwb" ]  && note "self keywords-b ${kwb#STD-FONT-KW-B }"
    [ -n "$gen" ]  && note "self generics ${gen#STD-FONT-GEN }"
    [ -n "$unit" ] && note "self units ${unit#STD-FONT-UNIT }"
    [ -n "$nta" ]  && note "self delivered ${nta#STD-FONT-NT-A }"
    [ -n "$ntb" ]  && note "self agreement ${ntb#STD-FONT-NT-B }"

    # The apparatus control every probe here carries: a run that never got as
    # far as reporting is not a lane with no fonts, and the difference has to
    # be visible in the log rather than inferred from a line that is missing.
    case "$ctl" in
        *eng=*) ctl_pass std.font.probe-ran "control font: the probe ran and named its engine" ;;
        *)      ctl_fail std.font.probe-ran "control font: STD-FONT-CTL was never observed, so nothing below is a reading" ;;
    esac

    # Whether the lane read a toolkit at all. Every comparison under this is
    # void on a lane that did not, so it is asked first and said out loud --
    # the same shape analyse_theme's `nsrc=null` control has.
    case "$nta" in
        *fonts=null*) ctl_fail std.font.fonts-read "control fonts: this lane read no toolkit, so every comparison here is void" ;;
        *source=*)    ctl_pass std.font.fonts-read "control fonts read=YES" ;;
        *)            ctl_fail std.font.fonts-read "control fonts: STD-FONT-NT-A was never observed" ;;
    esac

    # The delivery, both ways. `neutrino.fonts` is what the preload handed the
    # page and the custom properties are what the launcher wrote into this
    # document's stylesheet: two mechanisms, one measurement, and an app is
    # entitled to either. A lane where they disagree is a window whose two
    # accounts of one desktop differ -- which on macOS is exactly what would
    # happen if the page composed its own family lists.
    case "$ntb" in
        *fonts=null*)  ctl_skip std.font.delivery "control delivery not_asked: this lane read no fonts" ;;
        *match=15/15*) ctl_pass std.font.delivery "control delivery match=15/15 verdict=DELIVERED" ;;
        *match=*)      ctl_fail std.font.delivery "control delivery: the custom properties and neutrino.fonts disagree -- match=$(nt_field match "$ntb") first=$(nt_field first "$ntb")" ;;
        *)             ctl_fail std.font.delivery "control delivery: STD-FONT-NT-B was never observed" ;;
    esac

    # And the documented idiom on a lane that read nothing: a property the
    # launcher never sets must reach the generic named beside it. The twin of
    # the palette's `var(--neutrino-absent, Canvas)` control.
    local fb
    fb="$(nt_field fallback "$ntb")"
    case "$fb" in
        monospace)      ctl_pass std.font.fallback "control fallback var(--neutrino-font-nosuchrole, monospace)=monospace verdict=RESOLVED" ;;
        notasked|"")    ctl_skip std.font.fallback "control fallback not_asked" ;;
        *)              ctl_fail std.font.fallback "control fallback: an unset property reached '$fb' rather than the generic beside it" ;;
    esac

    # The engine's own reading of the same desktop, where it has one.
    #
    # Gated by lane and not skipped quietly, the way analyse_theme exempts `qt`
    # by name: on WebKitGTK the CSS2 `font: menu` keyword *is* the desktop's
    # font, so the engine has read independently what the launcher read and the
    # two numbers can be compared. On QtWebEngine those keywords are Chromium's
    # constants -- 16px Arial against a toolkit saying 12px -- and on WKWebView
    # they are per-role, so neither can be asked this question. A unit bug is a
    # third off; the tolerance is the pixel WebKit truncates and the launcher
    # does not.
    local agree delta src
    src="$(nt_field source "$nta")"
    agree="$(nt_field agree "$ntb")"
    delta="$(printf '%s' "$agree" | sed -n 's/.*delta:\([0-9.]*\).*/\1/p')"
    if [ "$src" != "gtk" ]; then
        ctl_skip std.font.agree "control agree not_asked: this engine's system font keywords are not the desktop's"
    elif [ -z "$delta" ]; then
        ctl_fail std.font.agree "control agree: no reading on a lane that has one -- got '$agree'"
    elif awk -v d="$delta" 'BEGIN { exit !(d <= 1) }'; then
        ctl_pass std.font.agree "control agree $agree verdict=AGREED"
    else
        ctl_fail std.font.agree "control agree: the launcher and the engine read different sizes off one desktop -- $agree"
    fi

    # Whether the six keywords are one font or six is the question that decides
    # whether CSS has any notion of a role at all, so it is lifted out of the
    # line rather than left for a reader to find inside it. Reported, never
    # asserted: it is a fact about an engine.
    case "$kwb" in
        *identical=*) note "self roles identical=$(nt_field identical "$kwb")" ;;
        *)            note "self roles unread" ;;
    esac

    if [ -n "$(field 2 '^STD-FONT-END')" ]; then
        ctl_pass std.font.end-observed "control end observed=YES"
    else
        ctl_fail std.font.end-observed "control font: STD-FONT-END was never observed, so the probe stopped early"
    fi
}

# One place that knows which analyser a probe wants. This was two identical
# case statements, one per language, with the same fallback in each.
nt_analyse() {
    case "$1" in
        geom)  analyse_geom ;;
        doc)   analyse_doc ;;
        win)   analyse_win ;;
        theme) analyse_theme ;;
        font)  analyse_font ;;
        *)     fail "no analysis for probe '$1'" ;;
    esac
}

# Standalone: the Windows lane's way in, and a way to replay a record by hand.
# Sourced, this does nothing and verify-std.sh drives the functions itself.
#
# The apparatus check is off unless asked for, and that is the boundary this
# whole file is drawn along. `check_apparatus` reports on the *instrument* --
# what the frame extents were, which route the origin came by, how late the
# slowest poll was -- and those are per-platform facts that only the sampler
# that took them can state. verify-std.ps1 has its own and keeps it. What
# crosses the language boundary is the analysis of the record, which is the
# half that is the same question everywhere.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    NT_APPARATUS=0
    case "${3:-}" in --apparatus) NT_APPARATUS=1 ;; esac
    PROBE="${1:?usage: analyse.sh <probe> <record.tsv> [--apparatus]}"
    REC="${2:?usage: analyse.sh <probe> <record.tsv> [--apparatus]}"
    [ -f "$REC" ] || { echo "FAIL: no record at '$REC'"; exit 1; }
    TURNS="$(wc -l < "$REC" | tr -d ' ')"
    [ "$NT_APPARATUS" = 1 ] && check_apparatus
    nt_analyse "$PROBE"
    note "totals probe=$PROBE failures=$FAILURES"
    exit "$FAILURES"
fi
