#!/usr/bin/env python3
# matrix.py - every case, on every lane, in one grid.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Usage: matrix.py [--markdown|--html] [--registry test/cases.tsv] <sheet.html>...
#
# sheetdiff.py answers "which assertions are made on more than one lane", and it
# answers it off the normalised sentence because that was the only identity an
# assertion had. That identity has two known faults: it folds every run of
# digits to `#`, so two assertions differing only in a number are one row; and
# it requires two languages to emit the same sentence to the byte, which
# verify-windows.ps1 has never done for the geometry and position facts it
# shares with verify-linux.sh.
#
# The rows carry a case id now, so this asks the question the other tool could
# only approximate: not "do these sentences look alike" but "what did each lane
# say about this case". A lane that failed where the others held is one line to
# find, and a lane that could not run the case at all says SKIP rather than
# being indistinguishable from a lane that never got there.
#
#   gh run download <run-id> -D /tmp/sheets
#   python3 test/matrix.py /tmp/sheets/*/*.html

import json
import os
import re
import sys

DIGEST = re.compile(
    r'<script type="application/json" id="nt-digest">\s*(\{.*?\})\s*</script>', re.S)

# What a cell says. `-` is the one that needed a name: the lane published a
# sheet and did not mention this case, which is different from the lane not
# having run and different again from the case not applying here.
# What a cell says. Three of these needed naming.
#
# `-` is a lane the registry says should have reported this case and did not.
# `.` is a lane the case does not apply to at all -- four of the ten lanes run
# no harness suite, and marking their cells the same as a genuine gap put
# thirty-three false holes per lane in the middle of the one column that is
# supposed to carry the signal.
# `skip` is different from both: the lane ran the case and said why it could
# not answer.
ABSENT = "-"
NOTAPP = "."
MARKS = {"PASS": "ok", "FAIL": "FAIL", "SKIP": "skip"}


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            m = DIGEST.search(fh.read())
    except OSError as exc:
        print("  no sheet at %s (%s)" % (path, exc), file=sys.stderr)
        return None
    if not m:
        print("  %s carries no digest; it is not counted" % path, file=sys.stderr)
        return None
    try:
        return json.loads(m.group(1))
    except ValueError as exc:
        print("  %s has a digest that does not parse (%s)" % (path, exc),
              file=sys.stderr)
        return None


def registry(path):
    """id -> (title, applies-to). Missing file is not fatal: the grid is still
    readable without it, it just cannot say which blanks were supposed to be
    filled."""
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("#") or "\t" not in line:
                    continue
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3:
                    out[parts[0]] = (parts[1], parts[2])
    except OSError:
        pass
    return out


def applies(spec, lane):
    return spec.strip() == "*" or lane in spec.split()


def build(paths, reg):
    lanes, grid = [], {}
    for p in sorted(paths):
        d = load(p)
        if not d:
            continue
        lane = d.get("lane") or os.path.basename(p)
        if lane not in lanes:
            lanes.append(lane)
        for c in d.get("cases", []):
            # A case can legitimately be reported more than once on one lane:
            # decoflip runs the geometry probe under two decoration settings and
            # the flip harnesses run the theme probe under two desktops, so the
            # same assertion is made once per configuration.
            #
            # FAIL wins, because a case that broke under any configuration did
            # break. Between the other two, PASS wins: a lane where one
            # configuration could not ask the question and another asked it and
            # got an answer did get an answer, and reporting that as `skip`
            # would hide a real reading behind a missing one.
            prev = grid.setdefault(c["id"], {}).get(lane)
            if prev == "FAIL":
                continue
            if prev == "PASS" and c["v"] == "SKIP":
                continue
            grid[c["id"]][lane] = c["v"]
    return lanes, grid


def rows(lanes, grid, reg):
    """Sorted so the rows worth acting on come first: cases that disagree across
    lanes, then cases that failed somewhere, then everything else by id."""
    def rank(cid):
        seen = [grid[cid].get(l, ABSENT) for l in lanes
                if applies(reg.get(cid, ("", "*"))[1], l)]
        real = [v for v in seen if v != ABSENT]
        # A gap counts as a disagreement. A case three lanes report and the
        # fourth does not is the same shape of question as one three lanes pass
        # and the fourth fails -- something is different about that lane and the
        # grid exists to put it where it will be seen. Sorting it with the quiet
        # rows is how it stays unnoticed.
        disagrees = len(set(real)) > 1 or (real and ABSENT in seen)
        failed = "FAIL" in real
        return (0 if disagrees else 1, 0 if failed else 1, cid)
    return sorted(grid, key=rank)


def text(lanes, grid, reg, holes):
    w = max([len(c) for c in grid] + [4])
    lw = [max(len(l), 5) for l in lanes]
    out = ["lanes compared (%d): %s" % (len(lanes), " ".join(lanes)), ""]
    out.append("%-*s  %s" % (w, "case", "  ".join(
        "%-*s" % (lw[i], l) for i, l in enumerate(lanes))))
    out.append("%-*s  %s" % (w, "-" * 4, "  ".join("-" * x for x in lw)))
    for cid in rows(lanes, grid, reg):
        spec = reg.get(cid, ("", "*"))[1]
        cells = []
        for i, l in enumerate(lanes):
            if not applies(spec, l):
                cells.append("%-*s" % (lw[i], NOTAPP))
                continue
            v = grid[cid].get(l, ABSENT)
            cells.append("%-*s" % (lw[i], MARKS.get(v, v)))
        out.append("%-*s  %s" % (w, cid, "  ".join(cells)))
    out.append("")
    out.append("ok = held   FAIL = did not hold   skip = the lane ran it and "
               "said why it could not answer")
    out.append("%s = this case does not apply to that lane   %s = the lane was "
               "expected to report it and did not" % (NOTAPP, ABSENT))
    if holes:
        out.append("")
        out.append("declared in cases.tsv and reported by no lane that it "
                   "applies to (%d):" % len(holes))
        for cid, where in holes:
            out.append("  %-*s  expected on: %s" % (w, cid, where))
    return "\n".join(out)


def markdown(lanes, grid, reg, holes):
    out = ["| case | " + " | ".join(lanes) + " |",
           "|---|" + "---|" * len(lanes)]
    for cid in rows(lanes, grid, reg):
        spec = reg.get(cid, ("", "*"))[1]
        cells = []
        for l in lanes:
            if not applies(spec, l):
                cells.append(NOTAPP)
                continue
            v = grid[cid].get(l, ABSENT)
            cells.append("**FAIL**" if v == "FAIL" else MARKS.get(v, v))
        out.append("| `%s` | " % cid + " | ".join(cells) + " |")
    out.append("")
    out.append("`ok` held &middot; `FAIL` did not hold &middot; `skip` the lane "
               "ran it and said why it could not answer &middot; `%s` does not "
               "apply to that lane &middot; `%s` expected there and not reported"
               % (NOTAPP, ABSENT))
    if holes:
        out.append("")
        out.append("**Declared and never reported (%d):** %s"
                   % (len(holes), ", ".join("`%s`" % c for c, _ in holes)))
    return "\n".join(out)


def main(argv):
    fmt, reg_path, paths = "text", "test/cases.tsv", []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--markdown":
            fmt = "markdown"
        elif a == "--text":
            fmt = "text"
        elif a == "--registry":
            i += 1
            reg_path = argv[i]
        else:
            paths.append(a)
        i += 1
    if not paths:
        print("usage: matrix.py [--markdown] [--registry F] <sheet.html>...",
              file=sys.stderr)
        return 2

    reg = registry(reg_path)
    lanes, grid = build(paths, reg)
    if not lanes:
        print("no sheet carried a digest; nothing to compare", file=sys.stderr)
        return 1

    # A hole is a case the registry says applies to a lane that reported a sheet
    # and did not mention it. Only lanes that published are considered: a lane
    # that did not run is a different problem and this is not the tool that
    # notices it.
    holes = []
    for cid, (_, spec) in sorted(reg.items()):
        want = [l for l in lanes if applies(spec, l)]
        missing = [l for l in want if l not in grid.get(cid, {})]
        if want and len(missing) == len(want):
            holes.append((cid, " ".join(missing)))

    print(markdown(lanes, grid, reg, holes) if fmt == "markdown"
          else text(lanes, grid, reg, holes))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
