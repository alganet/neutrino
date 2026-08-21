#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# verify-macos-tight.sh - Asserts the tight tier on macOS.
#
# Two halves, and neither is worth anything alone. A profile that denies
# everything passes a denial test and is useless, and a webview that comes up
# proves nothing if the profile around it permits everything. So this asserts
# that the app still works AND that the profile it wrote actually refuses
# things, using the profile the app generated rather than one written here.

set -euo pipefail

FAILURES=0
APP_CMD="${1:?usage: verify-macos-tight.sh <app.cmd> <screenshot-dir>}"
SHOTS="${2:-.}"

APP_DIR="$(cd "$(dirname "$APP_CMD")" && pwd)/$(basename "$APP_CMD" .cmd)"
PROFILE="$APP_DIR/neutrino.sb"

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== Can a real webview still come up under the profile? ==="
rm -f "${TMPDIR:-/tmp}/neutrino-title.txt"
bash "$APP_CMD" > "${TMPDIR:-/tmp}/neutrino-tight.log" 2>&1 &
if bash "$(dirname "$0")/verify-macos.sh" "$SHOTS"; then
    pass "the app ran confined"
else
    fail "the webview did not survive the tight tier; it is not viable as written"
fi
pkill -f "$(basename "$APP_CMD")" 2>/dev/null || true
echo "  app output: $(cat "${TMPDIR:-/tmp}/neutrino-tight.log" 2>/dev/null | head -3)"

echo "=== Did it actually write a profile? ==="
if [ -s "$PROFILE" ]; then
    pass "profile at $PROFILE"
else
    fail "no profile was written; the tier did nothing"
    echo "=== Results: $FAILURES failure(s) ==="
    exit 1
fi

# Everything below runs the profile the app itself generated, against a shell
# rather than against the app, so a denial is a denial and not a webview quirk.
confined() { /usr/bin/sandbox-exec -f "$PROFILE" /bin/sh -c "$1" >/dev/null 2>&1; }

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

echo "=== Results: $FAILURES failure(s) ==="
[ "$FAILURES" -eq 0 ]
