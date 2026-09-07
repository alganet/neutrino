#!/usr/bin/env python3
# workflow-lint.py - the workflow rules a YAML parser will not catch.
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# Usage: python3 test/lib/workflow-lint.py [.github/workflows/*.yml]
#
# ci.yml parses as YAML long after it has stopped being a valid workflow, and
# the failure mode is the expensive one: the run is created, dies in under a
# second with "this run likely failed because of a workflow file issue", and
# says nothing about which line. That is a whole round spent to learn that a
# job-level `env` may not read the `runner` context -- which it may not, and
# which cost exactly one round to find out.
#
# So the rules that have already been paid for, checked before a push.

import re
import sys

try:
    import yaml
except ImportError:
    print("workflow-lint: pyyaml is not installed; nothing checked", file=sys.stderr)
    sys.exit(0)

# What a `${{ }}` in each position is allowed to name. GitHub's list, trimmed to
# the ones this repository could plausibly reach for.
JOB_ENV_OK = {"github", "needs", "strategy", "matrix", "vars", "inputs", "secrets", "env"}
JOB_IF_OK = JOB_ENV_OK | {"always", "success", "failure", "cancelled"}

REF = re.compile(r"\$\{\{\s*([a-zA-Z_][a-zA-Z0-9_-]*)\s*\.")


def contexts(value):
    return set(REF.findall(str(value)))


def check(path):
    bad = []
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    for name, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for key, allowed in (("env", JOB_ENV_OK), ("if", JOB_IF_OK)):
            block = job.get(key)
            if block is None:
                continue
            used = contexts(block if isinstance(block, str) else yaml.dump(block))
            for ctx in sorted(used - allowed):
                bad.append(
                    "%s: job '%s' reads the '%s' context in its %s, which is not "
                    "one of: %s" % (path, name, ctx, key, ", ".join(sorted(allowed))))
        # A step that runs on windows gets pwsh unless it says otherwise, so a
        # `run:` written as shell needs `shell: bash` spelled out. Only checked
        # where the runner is named outright; a matrix would need resolving.
        runs_on = str(job.get("runs-on", ""))
        if "windows" in runs_on:
            for i, step in enumerate(job.get("steps") or []):
                if not isinstance(step, dict) or "run" not in step:
                    continue
                if step.get("shell"):
                    continue
                body = str(step["run"])
                if re.search(r"(^|\n)\s*(bash |sh |export |mkdir -p |\. )", body):
                    bad.append(
                        "%s: job '%s' step %d runs what looks like shell on a "
                        "windows runner with no `shell:`; it will get pwsh"
                        % (path, name, i))
    return bad


def main(argv):
    paths = argv or [".github/workflows/ci.yml"]
    bad = []
    for p in paths:
        bad += check(p)
    for b in bad:
        print("  FAIL: " + b)
    print("### workflow-lint: %d problem(s) in %d file(s)" % (len(bad), len(paths)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
