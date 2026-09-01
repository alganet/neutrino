#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# sheetdiff.py - which assertions are being made on more than one lane.
#
# Usage: sheetdiff.py <sheet.html> [<sheet.html> ...]
#        sheetdiff.py --only-shared <sheet.html> ...
#
# Every sheet carries its lane's assertions as JSON in a script block, and this
# intersects them. It exists because the redundancy question in this repository
# is not answerable one lane at a time: a job log says what that lane asserted,
# an annotation says it again with a cap on it, and neither can say that four
# lanes are asserting the same sentence.
#
# What it prints is a candidate list and not a verdict. An assertion made on
# eight lanes may be eight lanes' worth of waste or may be the one thing that
# has to hold everywhere -- the engine walk asserts the meaning of an exit
# status on four lanes on purpose, and `assemble.sh` runs on three because the
# three seds are not the same program. The tool finds the repetition; deciding
# which repetition is redundant needs someone who knows why the lane exists.
#
# Reads the sheets a run produced, so the natural way in is:
#   gh run download <run-id> -R alganet/neutrino -D /tmp/sheets
#   python3 test/sheetdiff.py /tmp/sheets/*/*.html

import json
import re
import sys

DIGEST = re.compile(
    r'<script type="application/json" id="nt-digest">\s*(\{.*?\})\s*</script>',
    re.S)


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            m = DIGEST.search(fh.read())
    except OSError as exc:
        print("  no sheet at %s (%s)" % (path, exc), file=sys.stderr)
        return None
    if not m:
        # Said out loud rather than skipped. A sheet built before the digest
        # landed looks exactly like a lane that asserted nothing, and the
        # difference is the whole reliability of the count below.
        print("  %s carries no digest; it is not counted" % path, file=sys.stderr)
        return None
    try:
        return json.loads(m.group(1))
    except ValueError as exc:
        print("  %s has a digest that does not parse (%s)" % (path, exc),
              file=sys.stderr)
        return None


def main(argv):
    only_shared = False
    if argv and argv[0] == "--only-shared":
        only_shared = True
        argv = argv[1:]
    if not argv:
        print("usage: sheetdiff.py [--only-shared] <sheet.html> ...",
              file=sys.stderr)
        return 2

    lanes = []
    where = {}
    for path in argv:
        d = load(path)
        if not d:
            continue
        lane = d.get("lane") or path
        lanes.append(lane)
        for a in d.get("asserted", []):
            where.setdefault(a["t"], set()).add(lane)

    if not lanes:
        print("no sheet carried a digest; nothing to compare", file=sys.stderr)
        return 1

    print("lanes compared (%d): %s" % (len(lanes), " ".join(sorted(lanes))))
    print()

    rows = sorted(where.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    shared = [r for r in rows if len(r[1]) > 1]
    alone = len(rows) - len(shared)

    if shared:
        print("asserted on more than one lane (%d of %d distinct):"
              % (len(shared), len(rows)))
        print()
        for text, ls in shared:
            print("%3d  %s" % (len(ls), text))
            print("     %s" % " ".join(sorted(ls)))
    else:
        print("no assertion appears on more than one lane.")

    if not only_shared and alone:
        print()
        print("asserted on exactly one lane: %d" % alone)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
