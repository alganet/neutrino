#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-offline.sh - what `build.sh --tier=offline` actually denies (Linux, macOS).
#
# A probe, this round, not a verifier. `--tier=offline` has never been built by
# anything in this repository and never been run on any engine; its only
# assertion is parse.sh comparing two strings. So there is no measured value to
# assert to yet, and asserting to a guess would put a PASS on one.
#
# What is asserted is the apparatus, because a probe whose controls are unread
# publishes noise:
#
#   target=UP        the server answers before either app is launched. A page
#                    reaching a closed port measures nothing, and it reads
#                    exactly like a policy that held.
#   OFFLINE-READY    each build came up, ran its page script and drove its
#                    native window. This is the reading an over-broad policy
#                    would take away: the injected script is what the document's
#                    `script-src` is documented as exempting, and if that
#                    exemption is not real the app is a blank window that
#                    refuses everything and passes.
#   default-tier hits  the shapes the default policy permits really do arrive.
#                    Nine MISSes under the offline tier mean nothing unless the
#                    same shapes HIT under the tier that allows them.
#
# The instrument is the target server's own request log, which is the only
# channel here not under test -- the page cannot report a leak over a link the
# policy is supposed to have cut. Both builds talk to one server, so the phases
# are separated by the log's line count rather than by two ports: a second
# listener is a second thing that can fail to come up.
#
# Usage: verify-offline.sh <default-tier app.cmd> <offline-tier app.cmd>

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONTROL_APP="${1:-}"
OFFLINE_APP="${2:-}"
PORT=8096
SHAPES="fetch xhr img css script frame beacon sse ws"
# Not shapes the policy governs: the two routes out of the process. Counted
# separately so they cannot be mistaken for a subresource the tier let through.
ESCAPES="external navout"
# The shapes the default policy leaves alone. script and frame are refused by
# both policies and so belong to the enforcement control, not to this list.
ALLOWED="fetch xhr img css beacon sse ws"
FAILURES=0

if [ ! -f "$CONTROL_APP" ] || [ ! -f "$OFFLINE_APP" ]; then
    echo "usage: verify-offline.sh <default-tier app.cmd> <offline-tier app.cmd>" >&2
    exit 2
fi

say()  { echo "report: $*"; }
fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------- what this platform answers
#
# Ground rule 6: where a platform answer is a finding rather than a fix, it is
# asserted to the value that was measured, so a change in either direction is a
# failure and not silence.
#
# `navout` is the request a top-level navigation makes on its way to being
# refused, and the four engines do not agree. gjs and Qt decide before the
# request and nothing reaches the host. macOS has no navigation policy at all --
# PR 6 measured that implementing the selector ships a window that never loads,
# so the guard is -stopLoading after the document has committed. Windows cancels
# in NavigationStarting, the target document never runs, and the GET arrives
# anyway. Neither is fixable from here; both are written down.
#
# macOS is `any`, and honestly so: it read HIT in two rounds and MISS in a third
# and nothing here explains the difference. What *is* known is that the guard PR
# 6 shipped for that platform does not run at all on this runner image --
# `webViewRef.stopLoading()` raises "stopLoading is not a function" and the
# driver logs "could not refuse navigation to ..." every time. So the HITs are
# not a request winning a race with a stop; there is no stop. That is a hole in
# PR 6's mechanism rather than in this tier, and it is filed on its own.
# Recorded rather than asserted until something explains the MISS: either answer
# is a finding, and asserting the value seen most often would only make this
# lane flaky on someone else's change.
case "$(uname -s)" in
    Darwin) EXPECT_NAVOUT=any;  BROWSERS="Safari firefox Google Chrome" ;;
    *)      EXPECT_NAVOUT=MISS; BROWSERS="" ;;
esac

# ------------------------------------------------------------ reading a title

TITLE_FILE="${TMPDIR:-/tmp}/neutrino-title.txt"
case "$(uname -s)" in
    Darwin)
        # No window the shell can query; the testing tier's status file is the
        # only channel, which is why both builds carry that tier.
        read_title()  { sed -n '1p' "$TITLE_FILE" 2>/dev/null || true; }
        clear_title() { rm -f "$TITLE_FILE"; }
        ;;
    *)
        if ! command -v xdotool >/dev/null 2>&1; then
            echo "verify-offline.sh: need xdotool to read a window title" >&2
            exit 1
        fi
        read_title() {
            local wid
            wid=$(xdotool search --name "^OFFLINE-" 2>/dev/null | tail -1) || true
            [ -n "$wid" ] && xdotool getwindowname "$wid" 2>/dev/null || true
        }
        clear_title() { :; }
        ;;
esac

# pkill -f would match this script's own argv, which names both apps, and a
# command substitution forks a copy of it carrying the same argv. Killing the
# verifier is not a subtle failure but it is an easy one to write.
#
# Matching on the app's name is also not enough, and round 1 lost the whole kde
# reading to it. PR 20 took the name away from the Qt launch path's document:
# `qml` is handed an unlinked descriptor, so the engine holding the window has
# `/dev/fd/9` on its command line and nothing that says which app it is. The
# window outlived the phase, the next phase read its title, and the readings
# were attributed to the wrong build. So the window is asked for its own pid,
# which is the only thing that knows.
kill_apps() {
    local pid wid
    for pid in $(pgrep -f neutrinooffline 2>/dev/null); do
        case "$pid" in "$$"|"$PPID") continue ;; esac
        case "$(ps -o command= -p "$pid" 2>/dev/null)" in
            *verify-offline*) continue ;;
        esac
        kill "$pid" 2>/dev/null || true
    done
    if command -v xdotool >/dev/null 2>&1; then
        for wid in $(xdotool search --name "^OFFLINE-" 2>/dev/null); do
            pid="$(xdotool getwindowpid "$wid" 2>/dev/null)" || continue
            [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        done
    fi
}

# ------------------------------------------------- where openExternal lands
#
# `neutrino.shell.openExternal` ends at the desktop's URI handler, so on the X
# lanes the handler is replaced with one that records the url and fetches it --
# which puts both halves of this probe in one place, the target server's log.
# Registered as the http scheme handler as well as put on PATH, because gjs asks
# Gio and Qt asks QDesktopServices before either falls back to xdg-open.
#
# There is no equivalent on macOS: NSWorkspace is not something a PATH entry can
# stand in front of, so that lane lets the real handler run and reports whatever
# arrives. A browser coming up mid-lane is why it is also killed afterwards.
EXTERNAL_LOG="$HOME/offline-external.log"
rm -f "$EXTERNAL_LOG"
# Created empty rather than on first write: `wc -l <` on a file that is not
# there is a shell diagnostic in the middle of the readings, and on the lanes
# with no shim it would be there for the whole run.
: > "$EXTERNAL_LOG"

install_handler() {
    local shim="$HOME/offline-shim"
    command -v xdotool >/dev/null 2>&1 || return 0
    mkdir -p "$shim" "$HOME/.local/share/applications" "$HOME/.config"
    # Records and does not fetch, and that is the whole point of round 3. When
    # it fetched, a url in the server's log had two possible authors -- the view
    # having issued the request, or the handler having been handed it and gone
    # and got it -- and gjs and Qt refuse a navigation and then forward the same
    # url to the handler, so both were live at once for `navout`. With the shim
    # silent, a line in the server's log can only be the view, and a line here
    # can only be openExternal. The two routes stop sharing an instrument.
    #
    # Nothing is lost by not fetching: that a url handed to the desktop's
    # browser gets retrieved is measured on the lanes with no shim, where the
    # real handler runs and the default tier reads external=HIT.
    cat > "$shim/xdg-open" <<EOS
#!/bin/sh
echo "handler \$*" >> "$EXTERNAL_LOG"
EOS
    chmod +x "$shim/xdg-open"
    PATH="$shim:$PATH"
    export PATH
    cat > "$HOME/.local/share/applications/neutrino-off-probe.desktop" <<EOS
[Desktop Entry]
Type=Application
Name=neutrino off-probe handler
Exec=$shim/xdg-open %u
Terminal=false
NoDisplay=true
MimeType=x-scheme-handler/http;x-scheme-handler/https;
EOS
    cat > "$HOME/.config/mimeapps.list" <<EOS
[Default Applications]
x-scheme-handler/http=neutrino-off-probe.desktop
x-scheme-handler/https=neutrino-off-probe.desktop
EOS
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    HANDLER=shim
}

kill_browsers() {
    case "$(uname -s)" in
        Darwin) pkill -x Safari 2>/dev/null || true ;;
    esac
}

HANDLER=system
install_handler
# Said either way, and said before anything is launched. A lane where this
# reads `system` opens whatever browser the machine has, with the probe's url
# in it -- which is the finding happening rather than being measured, and on a
# developer's desktop it is a browser window they did not ask for. It is only
# acceptable here because openExternal ends at NSWorkspace and ShellExecute,
# where there is no seam a PATH entry can stand in front of.
say "control external handler=$HANDLER"

# ------------------------------------------------------------------ the target

LOG="$HOME/offline-pages.log"
rm -f "$LOG" "$LOG.body" "$LOG.diag"
if ! PAGES_PID="$(NEUTRINO_TARGET_PORT=$PORT bash "$HERE/serve-target.sh" "$LOG")"; then
    fail "nothing answering on $PORT; every reading below would be a dead port"
    exit 1
fi
trap 'kill "$PAGES_PID" 2>/dev/null || true' EXIT
say "control target=UP port=$PORT"

# Every request the server saw since a mark, matched on the query this app
# stamps each shape with. -a because one stray byte makes grep call the whole
# file binary and count nothing.
hits_since() {
    sed -n "$(($1 + 1)),\$p" "$LOG" 2>/dev/null | grep -ac "k=$2" || true
}

# ------------------------------------------------------------------- one phase

run_phase() {
    local label="$1" app="$2"
    local mark ext_mark ready="" title="" deadline hits="" shape n waited app_pid handled browsers

    # A phase may not start while the last one's window is still on the screen.
    # This is a precondition and not tidiness: round 1's kde reading was the
    # previous build's title, read as this build's answer, and it looked exactly
    # like a real result. If the window will not go, the phase says so instead
    # of reporting what it can see.
    kill_apps
    waited=0
    while [ "$waited" -lt 30 ] && [ -n "$(read_title)" ]; do
        kill_apps
        sleep 1
        waited=$((waited + 1))
    done
    clear_title
    if [ -n "$(read_title)" ]; then
        fail "$label: a window from the previous phase would not go; readings here would be its"
        return
    fi

    mark="$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')"
    [ -n "$mark" ] || mark=0
    ext_mark="$(wc -l < "$EXTERNAL_LOG" 2>/dev/null | tr -d ' ')"
    [ -n "$ext_mark" ] || ext_mark=0

    bash "$app" > "$HOME/offline-$label.log" 2>&1 &
    app_pid=$!

    # Up to 90s for the first title, then 60s more for the settled one -- the
    # first launch on a cold runner is also the slowest, and a fixed total either
    # times out there or waits out the whole budget on a warm one. END and not
    # DONE: DONE is the nine-shape report, and the two escapes come after it.
    # An engine that permits the final navigation loses its document and never
    # sends END, which is what the outer bound is for.
    deadline=$((SECONDS + 90))
    while [ $SECONDS -lt $deadline ]; do
        title="$(read_title)"
        case "$title" in
            "OFFLINE-"*)
                if [ -z "$ready" ]; then
                    ready="$title"
                    deadline=$((SECONDS + 60))
                fi
                ;;
        esac
        case "$title" in *"END"*) break ;; esac
        sleep 0.5
    done

    # The navigation is sent two seconds after END. Where the real handler runs,
    # a browser also has to start cold and issue a request, which round 2
    # measured taking longer than ten seconds on the second launch of a lane --
    # macOS read external=MISS under the offline tier and external=HIT under the
    # default one for the same unchanged code path, which is a stopwatch and not
    # a refusal.
    case "$HANDLER" in
        shim) sleep 10 ;;
        *)    sleep 25 ;;
    esac

    if [ -z "$ready" ]; then
        fail "$label: the app never reported; a window that never came up refuses everything"
        say "$label: app said: $(tail -c 300 "$HOME/offline-$label.log" 2>/dev/null | tr '\n' ' ' | tr -d '[:cntrl:]')"
    else
        say "$label first: $ready"
        say "$label settled: ${title:-<none>}"
    fi
    eval "READY_${label}=\$ready"

    for shape in $SHAPES; do
        n="$(hits_since "$mark" "$shape")"
        if [ "${n:-0}" -gt 0 ]; then
            hits="$hits $shape=HIT"
            eval "HIT_${label}_${shape}=1"
        else
            hits="$hits $shape=MISS"
            eval "HIT_${label}_${shape}=0"
        fi
    done
    say "$label log:$hits"

    hits=""
    for shape in $ESCAPES; do
        n="$(hits_since "$mark" "$shape")"
        if [ "${n:-0}" -gt 0 ]; then
            hits="$hits $shape=HIT"
            eval "HIT_${label}_${shape}=1"
        else
            hits="$hits $shape=MISS"
            eval "HIT_${label}_${shape}=0"
        fi
    done
    # Which of the two the desktop's handler was asked to open, as opposed to
    # which merely reached the host. Without this a permitted navigation and a
    # refused one handed straight to the handler are the same HIT.
    # Trimmed, because the assertion downstream compares the whole string and a
    # trailing separator is not a reading.
    handled="$(sed -n "$((ext_mark + 1)),\$p" "$EXTERNAL_LOG" 2>/dev/null \
        | sed -n 's/.*[?&]k=\([a-z]*\).*/\1/p' | sort -u | tr '\n' ' ' \
        | sed -e 's/ *$//')"
    say "$label out of process:$hits handler-opened:${handled:- none}"
    eval "HANDLED_${label}=\"\${handled:-}\""

    # Where there is no shim, a browser having started is the reading the
    # handler log would have been. It is sampled before the phase's cleanup,
    # because the cleanup is what takes it away.
    if [ -n "$BROWSERS" ]; then
        browsers=""
        for shape in $BROWSERS; do
            pgrep -x "$shape" >/dev/null 2>&1 && browsers="$browsers $shape"
        done
        eval "BROWSERS_${label}=\"\${browsers:-}\""
        say "$label browsers running:${browsers:- none}"
    fi

    kill "$app_pid" 2>/dev/null || true
    kill_apps
    kill_browsers
    sleep 2
}

# --------------------------------------------------------------- the two phases

echo "=== default tier: what the shipped policy permits ==="
run_phase default "$CONTROL_APP"

echo "=== offline tier: what --tier=offline denies ==="
run_phase offline "$OFFLINE_APP"

# ------------------------------------------------------------------ the reading

# applyContentPolicy is a literal string replace with no failure path, so the
# document is asked which policy it ended up carrying rather than the build
# being trusted to have applied one.
pol_of() { echo "$1" | sed -n 's/.* pol=\([A-Z]*\).*/\1/p'; }
say "policy carried: default=$(pol_of "${READY_default:-}") offline=$(pol_of "${READY_offline:-}")"

leaked=""
delivered=""
missing=""
for shape in $SHAPES; do
    eval "o=\${HIT_offline_${shape}:-0}"
    [ "$o" = "1" ] && leaked="$leaked $shape"
done
for shape in $ALLOWED; do
    eval "d=\${HIT_default_${shape}:-0}"
    if [ "$d" = "1" ]; then delivered="$delivered $shape"; else missing="$missing $shape"; fi
done
say "reached the host under --tier=offline:${leaked:- none}"
say "the default tier delivered:${delivered:- none}"
say "the default tier permits but did not deliver:${missing:- none}"

# The two constants. Refused by both policies, so a hit on the default tier says
# this engine is not enforcing the document's policy at all -- and every MISS
# under the offline tier here would then be measuring something else.
enforced=YES
for shape in script frame; do
    eval "d=\${HIT_default_${shape}:-0}"
    [ "$d" = "1" ] && enforced=NO
done
say "the document's own policy is enforced (script/frame refused by both): $enforced"

# The tenth and eleventh questions, kept out of the table above because they are
# not subresource loads and no directive in either policy governs them. A HIT in
# the offline column is the tier's claim being false by a route the policy never
# had an opinion about.
escaped=""
for shape in $ESCAPES; do
    eval "o=\${HIT_offline_${shape}:-0}"
    [ "$o" = "1" ] && escaped="$escaped $shape"
done
say "left the process under --tier=offline:${escaped:- none}"

# ------------------------------------------------- what the fix has to be true of

assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "any" ]; then
        say "NOTE: $name = $actual (recorded, not asserted here)"
    elif [ "$actual" = "$expected" ]; then
        say "PASS: $name ($actual)"
    else
        fail "$name: expected $expected, got $actual"
    fi
}

# The document's policy. Nine shapes reach the host under the tier that permits
# them and none under the tier that does not -- the second line is the tier, the
# first is the control that stops it being a corpse.
assert "the offline document loaded nothing over the network" "" "$(
    for shape in $SHAPES; do
        eval "o=\${HIT_offline_${shape}:-0}"
        [ "$o" = "1" ] && printf ' %s' "$shape"
    done)"
assert "the document's own policy is enforced" "YES" "$enforced"
assert "the offline build carried the offline policy" "OFFLINE" "$(pol_of "${READY_offline:-}")"
assert "the default build carried the default policy" "DEFAULT" "$(pol_of "${READY_default:-}")"

# The route no content policy can see, and the half of this PR that is a fix
# rather than a measurement. Before it, both routes handed their url onward in
# both tiers -- measured, on this lane, three rounds running.
if [ "$HANDLER" = "shim" ]; then
    assert "the offline build handed the browser nothing" "" "${HANDLED_offline:-}"
    assert "the default build still opens a link (control)" "external navout" "${HANDLED_default:-}"
else
    # No handler to instrument here, so the reading is whether a browser
    # started. Before the fix one did, in both tiers.
    assert "no browser started under the offline tier" "" "${BROWSERS_offline:-}"
    [ -n "${BROWSERS_default:-}" ] || \
        say "NOTE: no browser started under the default tier either; the line above is not a refusal"
fi

# The ceiling, asserted to the value this platform was measured at.
assert "the navigation's own request, on this platform" "$EXPECT_NAVOUT" \
    "$(eval "o=\${HIT_offline_navout:-0}"; [ "$o" = "1" ] && echo HIT || echo MISS)"

# Recorded and not asserted: on a lane with a real handler, `external` arriving
# is a browser having started and won a race with the grace period. Round 2 read
# it both ways on one lane for the same unchanged code.
[ "$HANDLER" = "shim" ] || assert "external reached the host under the offline tier" "any" \
    "$(eval "o=\${HIT_offline_external:-0}"; [ "$o" = "1" ] && echo HIT || echo MISS)"

# --------------------------------------------------------------- the controls

[ -n "${READY_default:-}" ] && [ -n "${READY_offline:-}" ] || \
    fail "one of the two builds never came up; the comparison has one side"

# Not a per-shape assertion: an engine without EventSource is a reading, not a
# broken lane. An empty set is the apparatus being dead, and that is.
[ -n "$delivered" ] || \
    fail "nothing at all reached the host under the default tier; the probe measured its own plumbing"

echo "=== Results: $FAILURES failure(s) ==="
[ "$FAILURES" -gt 0 ] && exit 1
exit 0
