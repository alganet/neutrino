#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-macos-tight.sh - Asserts the tight tier on macOS.
#
# Two halves, and neither is worth anything alone. A profile that denies
# everything passes a denial test and is useless, and a webview that comes up
# proves nothing if the profile around it permits everything. So this asserts
# that the app still works AND that its profile actually refuses things, using
# the app's own generator rather than a profile written here.
#
# The generator is eval'd out of the built .cmd because there is no longer a
# file to read. run_macos used to write neutrino.sb into app_dir -- the one
# directory its own profile makes writable -- and this script read it back;
# that file was the finding, and it is gone. Extracting the three shell
# functions that build the profile is the only way left to assert against the
# text the app is actually confined by rather than against a second copy of it
# that can drift. If the extraction ever stops working it must fail loudly
# here, because an empty profile string refuses everything and would otherwise
# read as the strictest possible pass.

set -euo pipefail

FAILURES=0
APP_CMD="${1:?usage: verify-macos-tight.sh <app.cmd> <screenshot-dir>}"
SHOTS="${2:-.}"

APP_DIR="$(cd "$(dirname "$APP_CMD")" && pwd)/$(basename "$APP_CMD" .cmd)"
STALE_FILE="$APP_DIR/neutrino.sb"

# nt_sbquote is a one-liner, so it is printed by name and not as a range: sed
# prints a line once per matching range, and a range starting at it would run
# on to the next `}` and duplicate everything in between.
NT_FUNCS='/^nt_sbquote()/p; /^nt_resolve() {/,/^}/p; /^nt_macos_profile() {/,/^}/p'

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# gen_profile [tmpdir-override] -- the app's own profile, for the app's own dir
gen_profile() {
    (
        if [ $# -gt 0 ]; then TMPDIR="$1"; fi
        eval "$(sed -n "$NT_FUNCS" "$APP_CMD")"
        nt_macos_profile "$APP_DIR"
    ) 2>/dev/null
}

echo "=== Can a real webview still come up under the profile? ==="
mkdir -p "$APP_DIR"
rm -f "$STALE_FILE" "${TMPDIR:-/tmp}/neutrino-title.txt"
bash "$APP_CMD" > "${TMPDIR:-/tmp}/neutrino-tight.log" 2>&1 &
# The call below writes verify-macos.sh's own PASS lines and its own
# "=== Results: N failure(s) ===" into this script's output, so the log carries
# two result lines. Green they are indistinguishable;
# red, a reader cannot tell which verifier failed. So this script's three are
# labelled [tight] and the unlabelled one is verify-macos.sh's.
if bash "$(dirname "$0")/verify-macos.sh" "$SHOTS"; then
    pass "the app ran confined"
else
    fail "the webview did not survive the tight tier; it is not viable as written"
fi
pkill -f "$(basename "$APP_CMD")" 2>/dev/null || true
echo "  app output: $(cat "${TMPDIR:-/tmp}/neutrino-tight.log" 2>/dev/null | head -3)"

echo "=== Is there still a profile file to poison? ==="
# The finding, asserted from the outside. A file here was writable by the very
# app the profile confines, its rewrite each launch was unchecked, and a
# planted one that could not be overwritten was measured being launched under.
if [ -e "$STALE_FILE" ]; then
    fail "the app wrote $STALE_FILE; the profile is a file again and poisonable"
else
    pass "no profile file was written"
fi

echo "=== Is the app's own profile generator reachable? ==="
PROFILE="$(gen_profile)"
case "$PROFILE" in
    *"(deny file-write*)"*"(deny mach-lookup"*)
        pass "generator extracted, ${#PROFILE} bytes" ;;
    *)
        fail "could not extract a profile from $APP_CMD; every check below would pass by refusing everything"
        echo "=== Results: $FAILURES failure(s) [tight] ==="
        exit 1 ;;
esac

if ! /usr/bin/sandbox-exec -p "$PROFILE" /usr/bin/true >/dev/null 2>&1; then
    fail "seatbelt will not take the profile the app builds"
    echo "=== Results: $FAILURES failure(s) [tight] ==="
    exit 1
fi

# Everything below runs the profile the app itself generates, through -p, which
# is how the app runs it -- against a shell rather than against the app, so a
# denial is a denial and not a webview quirk.
confined() { /usr/bin/sandbox-exec -p "$PROFILE" /bin/sh -c "$1" >/dev/null 2>&1; }

echo "=== What the profile refuses ==="
# Each of these plants something from outside the sandbox and proves it works
# unconfined before asking whether the profile refuses it. Without that a
# machine with no ~/.ssh passes the secrets check by having no secrets, and a
# write that failed for its own reasons passes the execute check by never
# producing anything to execute. A test that cannot tell those apart is not
# testing the profile.
SECRET="$HOME/.ssh/neutrino-tight-probe"
mkdir -p "$HOME/.ssh" 2>/dev/null || true
echo "neutrino-probe-secret" > "$SECRET" 2>/dev/null || true

if grep -q neutrino-probe-secret "$SECRET" 2>/dev/null; then
    echo "  (control: the planted secret is readable unconfined)"
    if confined "grep -q neutrino-probe-secret \"$SECRET\""; then
        fail "a planted secret under ~/.ssh was readable"
    else
        pass "~/.ssh is not readable"
    fi
else
    fail "could not plant a secret to test with; the check would prove nothing"
fi
rm -f "$SECRET"

PROBE="$APP_DIR/neutrino-exec-probe.sh"
printf '#!/bin/sh\necho ran\n' > "$PROBE" 2>/dev/null || true
chmod +x "$PROBE" 2>/dev/null || true
if [ "$("$PROBE" 2>/dev/null)" = "ran" ]; then
    echo "  (control: the planted program runs unconfined)"
    if confined "\"$PROBE\""; then
        fail "the app dir is both writable and executable"
    else
        pass "what it can write, it cannot execute"
    fi
else
    fail "could not plant an executable to test with; the check would prove nothing"
fi
rm -f "$PROBE"

if echo probe > "$HOME/neutrino-tight-probe" 2>/dev/null; then
    rm -f "$HOME/neutrino-tight-probe"
    if confined "echo x > \"\$HOME/neutrino-tight-probe\""; then
        fail "a write to \$HOME was allowed"
        rm -f "$HOME/neutrino-tight-probe"
    else
        pass "a write outside the app dir is refused"
    fi
else
    fail "\$HOME is not writable unconfined; the check would prove nothing"
fi

echo "=== Can it launch out through LaunchServices? ==="
# The door that is not a file rule. Write xor execute stops the app running what
# it wrote; it does not stop the app asking someone else to. An .app bundle in
# the directory this profile makes writable, handed to LaunchServices, is
# spawned by a daemon that is in nobody's sandbox -- outside this profile and
# outside netinstall's, if netinstall is the one that launched us.
#
# Two ways to ask and the profile has to refuse both: /usr/bin/open, and
# NSWorkspace.openURL, which is the same request from inside any process that
# can reach AppKit. Denying the binary alone would leave the second wide open.
LSAPP="$APP_DIR/LsProbe.app"
LSMARK="${TMPDIR:-/tmp}/neutrino-lsprobe-$$"

plant_bundle() {
    rm -rf "$LSAPP"
    mkdir -p "$LSAPP/Contents/MacOS"
    printf '#!/bin/sh\n/usr/bin/touch "%s"\n' "$1" > "$LSAPP/Contents/MacOS/LsProbe"
    chmod +x "$LSAPP/Contents/MacOS/LsProbe"
    # A fresh identifier each time: LaunchServices may answer a repeat request
    # for a bundle it already knows out of its database rather than by spawning,
    # and that reads exactly like a denial.
    cat > "$LSAPP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LsProbe</string>
<key>CFBundleIdentifier</key><string>com.example.neutrino.lsprobe.$2</string>
<key>CFBundleName</key><string>LsProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
}

# LaunchServices spawns asynchronously, so a refusal and a slow launch look the
# same until the clock runs out. Every attempt gets the same clock.
launched() {
    local i
    for i in $(seq 1 20); do
        [ -e "$1" ] && return 0
        sleep 1
    done
    return 1
}

plant_bundle "$LSMARK-ctl" ctl
/usr/bin/open "$LSAPP" >/dev/null 2>&1 || true
if launched "$LSMARK-ctl"; then
    echo "  (control: the planted bundle does launch unconfined)"

    plant_bundle "$LSMARK-open" open
    confined "/usr/bin/open \"$LSAPP\"" || true
    if launched "$LSMARK-open"; then
        fail "a bundle in the app dir was launched through open(1)"
    else
        pass "open(1) cannot reach LaunchServices"
    fi

    plant_bundle "$LSMARK-ws" ws
    confined "/usr/bin/osascript -l JavaScript -e \"ObjC.import('AppKit'); \\\$.NSWorkspace.sharedWorkspace.openURL(\\\$.NSURL.fileURLWithPath('$LSAPP'))\"" || true
    if launched "$LSMARK-ws"; then
        fail "a bundle in the app dir was launched through NSWorkspace.openURL"
    else
        pass "NSWorkspace.openURL cannot reach LaunchServices either"
    fi
else
    fail "the planted bundle does not launch even unconfined; the check would prove nothing"
fi
rm -rf "$LSAPP"
rm -f "$LSMARK-ctl" "$LSMARK-open" "$LSMARK-ws"

echo "=== Does a path carrying a quote widen the profile? ==="
# Taking the profile out of a file does nothing about the profile's text. Every
# path in it lands inside an s-expression string literal, and a directory name
# may legally contain a `"`: unescaped, one closes that string and what follows
# is profile source. Measured before the fix -- TMPDIR of the shape below
# produced a second (subpath ...) covering all of $HOME, which seatbelt
# accepted without a word.
#
# widen=no on its own is not the pass. A path escaped into naming nothing also
# refuses to widen, and reads identically here, so the escaped profile has to
# still grant writes to the directory it is supposed to name.
INJ_ROOT="${TMPDIR:-/tmp}/neutrino-tight-inject"
INJ_DIR="$INJ_ROOT\") (subpath \"$HOME"
rm -rf "${INJ_ROOT}"* 2>/dev/null || true
mkdir -p "$INJ_DIR" 2>/dev/null || true
INJ_MARK="$HOME/neutrino-tight-inject-probe"
rm -f "$INJ_MARK"

if [ -d "$INJ_DIR" ] && echo x > "$INJ_DIR/control" 2>/dev/null; then
    echo "  (control: the quoted-path directory exists and is writable unconfined)"
    INJ_PROFILE="$(gen_profile "$INJ_DIR")"
    if [ -z "$INJ_PROFILE" ] || ! /usr/bin/sandbox-exec -p "$INJ_PROFILE" /usr/bin/true >/dev/null 2>&1; then
        fail "the profile built from a quoted path is not usable at all"
    else
        if /usr/bin/sandbox-exec -p "$INJ_PROFILE" \
            /bin/sh -c "echo x > \"$INJ_MARK\"" >/dev/null 2>&1; then
            fail "a quote in TMPDIR injected a wider grant into the profile"
            rm -f "$INJ_MARK"
        else
            pass "a quote in TMPDIR does not widen the profile"
        fi
        if NT_INJ_DIR="$INJ_DIR" /usr/bin/sandbox-exec -p "$INJ_PROFILE" \
            /bin/sh -c 'echo x > "$NT_INJ_DIR/escaped"' >/dev/null 2>&1; then
            pass "and the escaped path still names the directory it is for"
        else
            fail "the escaped path names nothing; the previous check passed for the wrong reason"
        fi
    fi
else
    fail "could not plant a quoted-path directory; the check would prove nothing"
fi
rm -rf "${INJ_ROOT}"* 2>/dev/null || true
rm -f "$INJ_MARK"

echo "=== What the profile must still allow ==="
if confined "echo x > \"$APP_DIR/writable-probe\""; then
    pass "its own dir stays writable"
    rm -f "$APP_DIR/writable-probe"
else
    fail "the app dir is not writable; the app cannot run"
fi

if confined "cat /etc/hosts"; then
    pass "system files stay readable"
else
    fail "system reads are broken; the profile is too tight to be useful"
fi

echo "=== Results: $FAILURES failure(s) [tight] ==="
[ "$FAILURES" -eq 0 ]
