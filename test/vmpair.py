#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# vmpair.py - two artifacts, alternating, because one after the other lies
#
# vmlaunch.py measures one artifact. Comparing two by running it twice does not
# work on this machine, and the way it fails is the expensive way: it produces a
# number that looks like a result.
#
# Measured. The same artifact read a 230ms median prefix in one session and
# 303ms in the next, so the drift between two blocks of runs is larger than any
# effect this project has gone looking for. Run sequentially, a build with the
# macOS and gjs drivers taken out of the Windows compile read 291ms against 303
# -- a 12ms win, and there is no win: alternating the same two builds ten times
# gives a paired difference with a median of +3ms, a mean of +10.5ms and a
# standard deviation of 105ms, three pairs of ten going the wrong way, one of
# them by 208ms. Separating 20ms from that spread would take about 110 pairs.
#
# And it is not that nothing is measurable. The same ten pairs on a 731 KB app
# compiled into the assembly against the same app in the @else branch give a
# median of +50ms and a mean of +46ms with a standard deviation of 36ms, nine of
# ten pairs agreeing. Sequential medians had called that one 95ms. So the naive
# method overstated the effect that existed and invented one that did not, in
# the same afternoon.
#
# Each build gets a fresh app folder and one discarded launch before the reading
# -- a first launch compiles the exe and creates a WebView2 profile, which is
# not the launch anybody is complaining about -- and then one reading. The pair
# is the unit, so whatever the machine was doing is shared between them.
#
# Usage:
#   bash test/mkapp.sh --testing <app.js> /tmp/a.cmd     # the two builds have
#   bash test/mkapp.sh --testing <app.js> /tmp/b.cmd     # to be --testing ones
#   python3 test/vmpair.py /tmp/a.cmd /tmp/b.cmd 10      # prints every pair
#
# See vmlaunch.py for the guest setup, and vmfloor.py for what a launch costs
# before this project writes a line of it.

import os, statistics, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vmlaunch as vm

if len(sys.argv) < 3:
    print("Usage: vmpair.py <before.cmd> <after.cmd> [pairs]", file=sys.stderr)
    raise SystemExit(2)
A, B = sys.argv[1], sys.argv[2]
PAIRS = int(sys.argv[3]) if len(sys.argv) > 3 else 10
a_vals, b_vals, diffs = [], [], []

for i in range(PAIRS):
    row = {}
    for tag, art in (("a", A), ("b", B)):
        vm.install(art)
        # The first launch of a fresh app folder compiles and builds a WebView2
        # profile; discarded the same way vmlaunch.py discards it.
        try:
            vm.launch(fresh=True)
        except Exception as e:
            print("  pair %d %s: warm-up did not finish (%s)" % (i + 1, tag, e))
        try:
            row[tag] = vm.row(vm.launch(fresh=False))["prefix"]
        except Exception as e:
            print("  pair %d %s: no reading (%s)" % (i + 1, tag, e))
            row[tag] = None
    if row.get("a") and row.get("b"):
        a_vals.append(row["a"]); b_vals.append(row["b"])
        diffs.append(row["a"] - row["b"])
        print("  pair %2d   before=%4d  after=%4d  diff=%+d" % (i + 1, row["a"], row["b"], diffs[-1]))
vm.kill()

if diffs:
    print("\nreport: n=%d pairs" % len(diffs))
    print("report: before  median %d  values %s" % (statistics.median(a_vals), sorted(a_vals)))
    print("report: after   median %d  values %s" % (statistics.median(b_vals), sorted(b_vals)))
    print("report: paired difference (before - after): median %+d, mean %+.1f" % (
        statistics.median(diffs), statistics.mean(diffs)))
    print("report: %d of %d pairs favour the smaller assembly" % (sum(1 for d in diffs if d > 0), len(diffs)))
    if len(diffs) > 1:
        print("report: stdev of the paired difference %.1f" % statistics.stdev(diffs))
