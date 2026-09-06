#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# vmfloor.py - what a launch costs before this project writes a line of it
#
# `start: 324ms of this process before its first line` is the second largest
# block in a warm launch and it is one number over four unrelated things: the
# CLR starting, the JScript runtime coming up, System.Windows.Forms arriving --
# init calls EnableVisualStyles three statements before the trace exists -- and
# this program's own global code running. Named "the prefix" it reads like a
# cost somebody chose. Some of it nobody can choose.
#
# So this compiles controls with the compiler the launcher uses, on the machine
# being complained about, and runs each of them six times in the logged-on
# user's session. Each is a JScript.NET winexe that does one thing and then
# reports how long it took to reach its first line:
#
#   empty     nothing. The CLR and the JScript runtime, and no program
#   styles    Application.EnableVisualStyles, which is what init opens with
#   evalp     one eval("1+1"), because eval is how this file reaches every
#             late-bound name and jsc has to carry an engine that can compile
#             at run time to offer it
#   evalsys   eval("System"), the exact spelling every driver here opens with
#   form      a Form constructed and its Handle realised, which is what
#             createWindow does and what a controller needs before it can be
#             asked for
#
# What they read on a Windows 11 Home VM, medians of six, against that
# machine's own 324ms prefix and 105ms frame:
#
#     empty 36   styles 37   evalp 58   evalsys 64   form 124
#
# Which says: the CLR and the JScript runtime are 36ms and nobody is getting
# them back. The toolkit is 1ms, so EnableVisualStyles is not the reason the
# prefix is what it is. The first eval costs 22ms, and eval("System") 28 --
# real, and the price of the late binding the polyglot is built on. And a Form
# with a handle is 87ms over the floor, which matches the 105ms the driver
# spends between `window  building the frame` and `frame built`: that cost is
# WinForms, not this code.
#
# Floor and not attribution, and the gap is the finding. 36 + 28 + 1 is 65 of
# 324, so about 260ms of the prefix belongs to this program -- loading and
# JIT-ing a 705 KB assembly, and running thirty-two parts of global code. A
# build with the macOS and gjs drivers stubbed out, 209 KB of source down to
# 180, measured 304ms against 324: 14% smaller for 6% faster. So the dead
# drivers are not free, and they are not the story either; what jsc compiles
# into every Windows exe is four platforms' worth of driver, and carrying them
# is worth roughly 140ms of every launch on that machine.
#
# That 20ms did not survive being measured again, and the reading above should
# be read as one median against another rather than as an effect. The drivers
# have since moved into the artifact's @else branch, so jsc.exe does not compile
# them at all -- 700,416 bytes of assembly down to 460,800, which is a larger
# cut than the stub experiment made -- and prefix was taken again as ten
# alternating pairs, the two builds taking turns so drift is shared. The paired
# difference was a median of +3ms and a mean of +10.5ms with a standard
# deviation of 105ms; readings for the same artifact ranged 203ms to 453ms, and
# three pairs of ten went the wrong way, one by 208ms. Separating 20ms from that
# spread needs about 110 pairs.
#
# Which is a fact about this instrument, not only about that change. Two medians
# taken in sequence on this machine differ by more than the effects being looked
# for here: the same artifact read 230ms in one session and 303ms in the next.
# A prefix comparison worth quoting is a paired one.
#
# Paired, real effects do show up, so this is a method and not an excuse. The
# same ten-pair run applied to a 731 KB app compiled in against the same app in
# the @else branch -- a 5,209,600 byte assembly against 460,800 -- gave a median
# of +50ms and a mean of +46ms with a standard deviation of 36ms, nine pairs of
# ten in the same direction. Sequential medians had called that one 95ms. So the
# naive method overstated the effect that was there and invented the one that
# was not, which is the argument for alternating in both directions at once.
#
# Usage: python3 test/vmfloor.py   (see vmlaunch.py for the guest setup)

import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vmlaunch as vm

REFS = ["mscorlib.dll", "System.dll", "System.Configuration.dll", "Accessibility.dll",
        "System.Drawing.dll", "System.Windows.Forms.dll", "System.IO.Compression.dll",
        "System.IO.Compression.FileSystem.dll"]

IMPORTS = ("import System;\r\nimport System.IO;\r\nimport System.Diagnostics;\r\n"
           "import System.Drawing;\r\nimport System.Windows.Forms;\r\n")

# Appended rather than written, so one task run can hold every iteration of
# every control and the whole sweep is a single trip into the guest.
STAMP = ("var ms = Math.round(DateTime.UtcNow.Subtract(\r\n"
         "    Process.GetCurrentProcess()\r\n"
         "        .StartTime.ToUniversalTime()).TotalMilliseconds);\r\n"
         "File.AppendAllText(\r\n"
         "    Environment.GetCommandLineArgs()[1], ms + \"\\r\\n\");\r\n")

PROBES = [
    ("empty", ""),
    ("styles", "Application.EnableVisualStyles();\r\n"
               "Application.SetCompatibleTextRenderingDefault(false);\r\n"),
    ("evalp", "var q = eval(\"1+1\");\r\n"),
    ("evalsys", "var SystemRef = eval(\"System\");\r\n"
                "var q = SystemRef.DateTime.UtcNow;\r\n"),
    ("form", "Application.EnableVisualStyles();\r\n"
             "Application.SetCompatibleTextRenderingDefault(false);\r\n"
             "var f : Form = new Form();\r\n"
             "f.ClientSize = new Size(800, 600);\r\n"
             "var h = f.Handle;\r\n"),
]


def framework():
    for d in (r"C:\Windows\Microsoft.NET\Framework64\v4.0.30319",
              r"C:\Windows\Microsoft.NET\Framework\v4.0.30319"):
        rc, out, _ = vm.cmd("if exist " + d + "\\jsc.exe (echo yes) else (echo no)")
        if "yes" in out:
            return d
    raise RuntimeError("no jsc.exe in the guest")


def main(runs=6):
    fx = framework()
    print("report: jsc under " + fx)
    vm.cmd("mkdir " + vm.WORK + " 2>nul & exit 0")
    for name, head in PROBES:
        src = "/tmp/.vmfloor-%s.js" % name
        open(src, "w").write(IMPORTS + head + STAMP)
        vm.push(src, vm.WORK + "\\%s.js" % name)
        rc, out, err = vm.cmd(
            fx + "\\jsc.exe /nologo /debug- /t:winexe /out:" + vm.WORK + "\\" + name +
            ".exe /autoref+ /lib:" + fx + " " +
            " ".join("/r:" + fx + "\\" + r for r in REFS) +
            " " + vm.WORK + "\\" + name + ".js", wait=300)
        if rc:
            print("FAIL: %s would not compile: %s" % (name, (out + err).strip()[:200]))

    bat = "@echo off\r\n"
    for name, _ in PROBES:
        bat += "del /q " + vm.WORK + "\\%s.txt 2>nul\r\n" % name
        for _ in range(runs):
            bat += ("start /wait " + vm.WORK + "\\%s.exe " % name +
                    vm.WORK + "\\%s.txt\r\n" % name)
    open("/tmp/.vmfloor.bat", "w").write(bat)
    vm.push("/tmp/.vmfloor.bat", vm.WORK + "\\floor.bat")
    # In the user's session for the same reason vmlaunch.py registers a task:
    # a Form built by SYSTEM in session 0 has no desktop, and `form` is the
    # control that has to be comparable with what createWindow actually does.
    vm.cmd("schtasks /create /tn neutrinofloor /tr " + vm.WORK + "\\floor.bat"
           " /sc once /st 00:00 /ru " + vm.USER + " /it /f")
    vm.cmd("schtasks /run /tn neutrinofloor")
    time.sleep(8 + 2 * runs * len(PROBES))
    for name, _ in PROBES:
        try:
            vals = sorted(int(x) for x in
                          vm.pull(vm.WORK + "\\%s.txt" % name).decode().split())
        except Exception as e:
            print("report: %-8s no reading (%s)" % (name, e))
            continue
        print("report: %-8s %s  median %d" % (name, vals, vals[len(vals) // 2]))


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 6)
