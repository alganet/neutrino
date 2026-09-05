#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# vmlaunch.py - what a launch costs on a client machine, measured from outside it
#
# Every number this project had for a Windows launch came from a GitHub runner:
# Windows Server, no scanner in front of CreateProcess, and 934ms to the title.
# The machine that was actually slow was a Windows 11 Home VM, and the loop for
# reading it was a person copying an artifact in, double clicking it, and
# copying neutrino-trace.log back out. Three round trips like that cost an
# afternoon and produced three samples, two of which turned out to be measuring
# a cold WebView2 runtime rather than a launch.
#
# libvirt already had the machine. This drives it through the QEMU guest agent:
# push the artifact, run it, read the trace back, repeat. A run takes ten
# seconds and nobody has to be at the keyboard, which is what turns "is it
# Defender" and "is it the Desktop" from arguments into readings -- both were
# asked here and both came back no.
#
# Setup, once. The guest needs qemu-ga (virtio-win ships it as
# guest-agent\qemu-ga-x86_64.msi) and the domain needs the channel it talks
# over, which libvirt does not add by default:
#
#     virsh attach-device <domain> chan.xml --live --config
#     <channel type='unix'>
#       <target type='virtio' name='org.qemu.guest_agent.0'/>
#     </channel>
#
# Three things about the guest agent that are not obvious and each cost a
# wrong reading here:
#
#   session   guest-exec runs as SYSTEM in session 0. A GUI app started that
#             way has no desktop, and it is not what a double click measures.
#             So the artifact is launched through a scheduled task registered
#             `/ru <user> /it`, which runs it in the logged-on user's session
#             with no stored password.
#
#   quotes    the agent hands CreateProcess an argument vector and escapes
#             embedded quotes the way a C runtime would, which cmd.exe does not
#             read the same way. A quoted path silently does not run -- and a
#             delete that did not happen reads exactly like a launch that did,
#             which is five byte-identical traces and an hour. Nothing below
#             quotes anything; the work directory has no spaces.
#
#   reading   nothing reads the trace while the app is writing it. noteSink
#             swallows what AppendAllText throws, so a reader that holds the
#             file for a moment does not produce an error -- it produces a
#             trace with a line missing, which reads as a phase that did not
#             happen. `window  frame built` and `evergreen: types emitted`
#             each went absent that way. The wait is fixed and the read is
#             once.
#
# The first run of a fresh app folder compiles the exe and creates a WebView2
# profile, so it is discarded rather than averaged in: it is not the launch
# anybody is complaining about.
#
# What it read the day it was written, on a Windows 11 Home VM, four warm runs,
# medians, in milliseconds from the driver's first line except `prefix`:
#
#     prefix 324   frame 209   emit0 227   emit1 237
#     ask    288   onscreen 347   ctrl 696   title 974
#
# So about 1.3 seconds in the process, plus a batch region of roughly 150ms
# that this cannot see. Three readings in there are worth keeping because each
# had been argued about and none of the arguments survived:
#
#   the emitter is 10ms. `emit0` to `emit1` is 230 interface methods being
#   written to place the 34 this driver calls, which js/webview2-evergreen.js
#   calls "the kind of ratio that invites a rewrite" and then declines to give
#   one. It was right.
#
#   the Form is about 105ms, from `window  building the frame` to `frame
#   built`, and it is the largest single thing in front of the browser.
#   Nothing can ask for a controller earlier, because a controller needs a
#   window handle.
#
#   the browser is 408ms, `ask` to `ctrl`, and the process table says the tree
#   is a browser, a crashpad handler, two utilities, a GPU process at +205ms
#   and a renderer at +344ms. Which is what a Chromium costs, not a pathology.
#
# And two hypotheses this killed. A process start on that machine is 18ms, so
# the launcher's stamp was never the story; and the same artifact run from the
# Desktop and from C:\nt came back 288 against 313, so the profile directory
# is not one either. Both had sounded obvious.
#
# Usage:
#   bash test/mkapp.sh --testing test/neutrinoloaders.js /tmp/probe.cmd
#   python3 test/vmlaunch.py /tmp/probe.cmd [runs] [--fresh] [--raw]
#
# Environment: NEUTRINO_VM (domain, default win11), NEUTRINO_VM_USER (the
# logged-on user, default win), NEUTRINO_VM_DIR (work directory in the guest,
# default C:\nt -- no spaces, see `quotes` above).

import base64, json, os, re, subprocess, sys, time

DOM = os.environ.get("NEUTRINO_VM", "win11")
USER = os.environ.get("NEUTRINO_VM_USER", "win")
WORK = os.environ.get("NEUTRINO_VM_DIR", "C:\\nt")
NAME = "neutrinovm"
ART = WORK + "\\" + NAME + ".cmd"
APPDIR = WORK + "\\" + NAME
TRACE = APPDIR + "\\neutrino-trace.log"
DONE = "the stamp's hash costs"


def qga(cmd, args=None, timeout=60):
    payload = {"execute": cmd}
    if args is not None:
        payload["arguments"] = args
    p = subprocess.run(["virsh", "qemu-agent-command", DOM, json.dumps(payload)],
                       capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError("%s: %s" % (cmd, p.stderr.strip()))
    return json.loads(p.stdout)["return"]


def push(local, remote, chunk=48 * 1024):
    data = open(local, "rb").read()
    handle = qga("guest-file-open", {"path": remote, "mode": "wb"})
    try:
        for i in range(0, len(data), chunk):
            qga("guest-file-write", {"handle": handle,
                                     "buf-b64": base64.b64encode(data[i:i + chunk]).decode()})
    finally:
        qga("guest-file-close", {"handle": handle})
    return len(data)


def pull(remote, chunk=48 * 1024):
    handle = qga("guest-file-open", {"path": remote, "mode": "rb"})
    out = b""
    try:
        while True:
            r = qga("guest-file-read", {"handle": handle, "count": chunk})
            if r.get("buf-b64"):
                out += base64.b64decode(r["buf-b64"])
            if r.get("eof") or not r.get("count"):
                break
    finally:
        qga("guest-file-close", {"handle": handle})
    return out


def cmd(line, wait=120):
    pid = qga("guest-exec", {"path": "C:\\Windows\\System32\\cmd.exe",
                             "arg": ["/c", line], "capture-output": True})["pid"]
    deadline = time.time() + wait
    while time.time() < deadline:
        st = qga("guest-exec-status", {"pid": pid})
        if st.get("exited"):
            dec = lambda k: (base64.b64decode(st[k]).decode("utf-8", "replace")
                             if st.get(k) else "")
            return st.get("exitcode"), dec("out-data"), dec("err-data")
        time.sleep(0.2)
    raise TimeoutError("guest pid %s did not exit" % pid)


def kill():
    # The app only, and never msedgewebview2 by name. A WebView2 browser
    # belongs to whichever host started it, and this machine has several --
    # SearchHost.exe had six of them up during one of these runs. Killing them
    # all took somebody else's browser down and raced our own profile lock:
    # the next launch answered 0x800700AA, ERROR_BUSY, from
    # CreateCoreWebView2Controller, and the app reported "the installed
    # WebView2 runtime started but would not give this window a view". The
    # browser exits when its host does, so taking the host is enough; the wait
    # is for it to finish doing so.
    cmd("taskkill /IM " + NAME + ".exe /F >nul 2>&1 & exit 0")
    time.sleep(2)


def gone(path, tries=40):
    for _ in range(tries):
        try:
            pull(path)
        except Exception:
            return True
        time.sleep(0.25)
    return False


def install(local):
    cmd("mkdir " + WORK + " 2>nul & exit 0")
    push(local, ART)
    tmp = "/tmp/.vmlaunch-task.bat"
    open(tmp, "w").write("@echo off\r\n" + ART + "\r\n")
    push(tmp, WORK + "\\launch.bat")
    cmd("schtasks /create /tn neutrinovm /tr " + WORK + "\\launch.bat"
        " /sc once /st 00:00 /ru " + USER + " /it /f")


def launch(fresh=False, settle=9, tries=12):
    kill()
    if fresh:
        cmd("rmdir /s /q " + APPDIR + " 2>nul & del /q " + WORK + "\\" + NAME +
            ".exe " + WORK + "\\" + NAME + ".stamp 2>nul & exit 0")
    else:
        cmd("del /q " + TRACE + " 2>nul & exit 0")
    if not gone(TRACE):
        raise RuntimeError("the trace would not go away, so this run would be the last one")
    cmd("schtasks /run /tn neutrinovm")
    for _ in range(tries):
        time.sleep(settle)
        try:
            text = pull(TRACE).decode("utf-8", "replace")
        except Exception:
            continue
        if DONE in text:
            return text
    raise TimeoutError("no finished trace")


def mark(text, needle):
    for line in text.splitlines():
        m = re.match(r"^(-?\d+)ms neutrino: (.*)$", line)
        if m and needle in m.group(2):
            return int(m.group(1))
    return None


COLUMNS = [
    ("prefix", None), ("toTrace", None), ("frame", "window  frame built"),
    ("emit0", "evergreen: emitting types"), ("emit1", "evergreen: types emitted"),
    ("ask", "controller asked for"), ("onscreen", "attach  window on screen"),
    ("ctrl", "evergreen  controller up"), ("title", "title -> "),
]


def row(text):
    pre = re.search(r"start: (\d+)ms of this process", text)
    split = re.search(r"start: (\d+)ms of that reached", text)
    out = {"prefix": int(pre.group(1)) if pre else None,
           "toTrace": int(split.group(1)) if split else None}
    for name, needle in COLUMNS:
        if needle:
            out[name] = mark(text, needle)
    return out


def main():
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    fresh = "--fresh" in sys.argv
    raw = "--raw" in sys.argv
    local = argv[0]
    runs = int(argv[1]) if len(argv) > 1 else 5
    install(local)
    rows = []
    for i in range(1, runs + 1):
        text = launch(fresh=(fresh and i == 1))
        if raw:
            print("=== run %d ===" % i)
            print(text.strip(), "\n")
        rows.append(row(text))
    kill()
    names = [c[0] for c in COLUMNS]
    print(" ".join("%9s" % n for n in ["run"] + names))
    for i, r in enumerate(rows, 1):
        label = "%d%s" % (i, "c" if fresh and i == 1 else "")
        print(" ".join("%9s" % v for v in [label] + [r[n] for n in names]))
    warm = rows[1:] if fresh else rows
    if warm:
        def med(n):
            vals = sorted(r[n] for r in warm if r[n] is not None)
            return vals[len(vals) // 2] if vals else None
        print(" ".join("%9s" % v for v in ["median"] + [med(n) for n in names]))


if __name__ == "__main__":
    main()
