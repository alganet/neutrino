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
#   python3 test/report/matrix.py /tmp/sheets/*/*.html

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
    lanes, grid, filed = [], {}, {}
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
            filed.setdefault(lane, set()).add(c.get("suite", ""))
    return lanes, grid, filed


def manifest(path):
    """The rows a lane is expected to run, from test/suites.tsv: a dict of
    lane -> set of suite names, leaving out the rows that are not expected to
    file anything under their own name.

    Two kinds are left out and each says so in the row. `soft` is the manifest's
    word for a reading nobody asserts -- cases.tsv says readings must not become
    cases, so a soft row filing nothing is the row working. `subsuites` is a row
    whose command is itself a runner: netinstall/test/run.sh exports NT_SUITE per
    suite it runs, so those five rows file under `env`, `e2e`, `splash` and a
    dozen more and never under `netinstall`.

    None when the file could not be read at all, and a dict -- possibly an empty
    one -- when it could. The difference matters and cost a round to find: a
    manifest whose every row is `soft` or `subsuites` is readable and yields
    nothing to check, which is not the same as a manifest that is not there.
    Collapsing the two made --strict refuse a run whose manifest it had read
    perfectly well."""
    rows = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("#") or not line.strip():
                    continue
                part = line.rstrip("\n").split("\t")
                if len(part) < 4:
                    continue
                suite, lanespec, setup = part[0], part[1].split(), part[2].split()
                if "soft" in setup or "subsuites" in setup:
                    continue
                for l in lanespec:
                    # `<lane>:<phase>` names one pass of a lane that runs its
                    # list twice. Everything left of the colon is what reaches
                    # $NT_LANE, so it is what a sheet is keyed on.
                    rows.setdefault(l.split(":")[0], set()).add(suite)
    except OSError:
        return None
    return rows


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
        out.append("declared in cases.tsv and not reported by every lane it "
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
    fmt, reg_path, paths, strict = "text", "test/cases.tsv", [], False
    suites_path = "test/suites.tsv"
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--markdown":
            fmt = "markdown"
        elif a == "--text":
            fmt = "text"
        elif a == "--strict":
            strict = True
        elif a == "--registry":
            i += 1
            reg_path = argv[i]
        elif a == "--suites":
            i += 1
            suites_path = argv[i]
        else:
            paths.append(a)
        i += 1
    if not paths:
        print("usage: matrix.py [--markdown] [--registry F] <sheet.html>...",
              file=sys.stderr)
        return 2

    reg = registry(reg_path)
    lanes, grid, filed = build(paths, reg)
    if not lanes:
        print("no sheet carried a digest; nothing to compare", file=sys.stderr)
        return 1

    # A hole is a case the registry says applies to a lane that reported a sheet
    # and did not mention it. Only lanes that published are considered: a lane
    # that did not run is a different problem and this is not the tool that
    # notices it.
    #
    # *Any* missing lane, not only a case missing on all of them. This asked
    # `len(missing) == len(want)` until now, so a case three lanes reported and
    # the fourth did not was drawn as a `-` and exited 0 -- while rank() above
    # was already sorting that row to the top and saying why in its own comment:
    # "a case three lanes report and the fourth does not is the same shape of
    # question as one three lanes pass and the fourth fails". One file, two
    # answers, and the exit status had the wrong one.
    #
    # Found by a grid diff: three env.toolkit.* cases went missing on
    # macos-netinstall when netinstall/test/env.sh was converted, because the
    # Darwin arm of its toolkit block set two variables and filed no rows. The
    # diff against the previous run showed it; --strict returned 0.
    holes = []
    for cid, (_, spec) in sorted(reg.items()):
        want = [l for l in lanes if applies(spec, l)]
        missing = [l for l in want if l not in grid.get(cid, {})]
        if want and missing:
            holes.append((cid, " ".join(missing)))

    print(markdown(lanes, grid, reg, holes) if fmt == "markdown"
          else text(lanes, grid, reg, holes))

    # Two things that are wrong with the *run* rather than with the product, and
    # that only this tool can see because only this tool reads all ten sheets.
    #
    # Until now it could see them and say nothing: the matrix job is
    # `if: always()` and this returned 0 whatever it found, so the grid was a
    # thing a person had to read and compare by hand. Both of the following have
    # actually happened, and both were caught by a human diffing two grids.
    #
    # A lane that went quiet: it published a sheet, the registry says cases
    # apply to it, and it reported none of them. That is what four lanes looked
    # like before the netinstall suites spoke this vocabulary, and it is what a
    # lane looks like when its results directory is never created -- a `cp` with
    # `|| true` on the end that copies nothing, which cannot fail on its own.
    quiet = []
    for lane in lanes:
        want = [cid for cid, (_, spec) in reg.items() if applies(spec, lane)]
        if not want:
            continue
        got = [cid for cid in want if lane in grid.get(cid, {})]
        if not got:
            quiet.append((lane, len(want)))

    # A case id no registry row declares. cases.tsv is meant to be the list of
    # every assertion this suite makes, and an id that reaches a sheet without
    # being in it is either a typo or something that is not an assertion at all:
    # a walk *record* was once read as rows and put two cases in this grid
    # called `500x400` and `900x600`.
    stray = sorted(cid for cid in grid if cid not in reg)

    # A row that ran and filed nothing under its own name.
    #
    # The three checks above all start from cases.tsv, so they can only see a
    # suite that registered ids and then failed to emit them. The suite that
    # registers none at all is invisible to every one of them: no holes, no
    # quiet lane, no stray id, and a green run that asserts into prose. That was
    # true of eleven rows across six suites until 2026-09-20, one of which had
    # thirty assertions and no passing voice at all, and every one of them was
    # found by reading sheets by hand rather than by anything here.
    #
    # So this starts from the manifest instead: every row the lane was asked to
    # run should have filed at least one case under its own name. The two kinds
    # of row that should not are left out by manifest() above, and each of them
    # says which it is in its own setup column rather than being named here.
    #
    # Only lanes that published are considered, for the reason the hole check
    # gives: a lane that did not run is a different problem and this is not the
    # tool that notices it.
    rows = manifest(suites_path)
    silent = []
    for lane in lanes:
        for suite in sorted((rows or {}).get(lane, ())):
            if suite not in filed.get(lane, ()):
                silent.append((lane, suite))

    if quiet:
        print()
        print("lanes that published a sheet and reported none of their cases (%d):"
              % len(quiet))
        for lane, n in quiet:
            print("  %-20s %d case(s) apply and none were reported" % (lane, n))
    if stray:
        print()
        print("case ids in a sheet that cases.tsv does not declare (%d):" % len(stray))
        for cid in stray:
            print("  %s   on: %s" % (cid, " ".join(sorted(grid[cid]))))
    if silent:
        print()
        print("rows that ran and filed no case under their own name (%d):"
              % len(silent))
        for lane, suite in silent:
            print("  %-20s %s" % (lane, suite))
    elif rows is None:
        print()
        print("no suites manifest was read, so nothing was checked for silent rows")
        print("  (--suites names it; the default is test/suites.tsv)")

    # Holes count too, and did not until now. This asked only about `quiet` and
    # `stray`, so a case its registry says applies to four lanes and three
    # reported was drawn as a `-`, printed in the list above, and exited 0 --
    # which meant the one reader who had to notice it was a human comparing two
    # grids. Three of them arrived that way in one push and the diff caught what
    # this did not.
    #
    # A hole is the same failure as a quiet lane at a finer grain: the lane
    # published, the registry expected the case, and nothing was filed. There is
    # no reason for one of those to fail the run and the other to pass it.
    # An unread manifest fails --strict, and this is the check that would
    # otherwise be the easiest of the four to lose. A missing registry already
    # fails loudly by accident -- every id in every sheet becomes a stray -- but
    # a missing manifest makes `silent` empty, which reads exactly like every
    # row having filed. That is the shape of defect this whole check was added
    # for, and it would have been in the checker itself.
    #
    # --strict means this run was structurally sound, and a check that could not
    # run has not established that. A caller reading sheets from somewhere else
    # can point --suites at the manifest those sheets were produced by, the way
    # --registry pins cases.tsv, or leave --strict off.
    if strict and rows is None:
        return 1
    if strict and (quiet or stray or holes or silent):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
