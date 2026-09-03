# hostile.py - an http server that answers the way a compromised host would
#
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# nt_serve's python -m http.server cannot express any of this: it always sends
# a truthful Content-Length, which is the one response shape a size guard has
# no trouble with. The shapes below are the ones that decide whether the bound
# is real -- a length that is absent, a length that lies, and a body that never
# ends.
#
# Usage: hostile.py <port> <dir> [<stall-ms>]
#
# A path that names an existing file in <dir> is served truthfully, so the same
# server carries the suite's positive control. Everything else routes on its
# name; the .cmd suffix netinstall appends is ignored.
#
# <stall-ms> holds every truthful response for that long before its first
# byte. Not a hostile shape -- it is what an honest host on a real network
# looks like, and it exists because nt_serve's loopback answers in a few
# milliseconds, which is faster than the splash is allowed to appear. A suite
# that wants to see the window needs a download that takes long enough to
# deserve one, and this is the one knob that makes the truthful path slow
# without making it lie.

import os
import socket
import sys
import threading
import time

BIG = 64 * 1024 * 1024
BLK = b"a" * 65536


def send_body(conn, total):
    sent = 0
    while sent < total:
        conn.sendall(BLK)
        sent += len(BLK)


def respond(conn, path, root, stall):
    name = path.lstrip("/").split("?")[0]
    disk = os.path.join(root, os.path.basename(name))
    if name and os.path.isfile(disk):
        with open(disk, "rb") as fh:
            body = fh.read()
        if stall:
            time.sleep(stall / 1000.0)
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body))
        conn.sendall(body)
        return

    shape = os.path.basename(name)
    if shape.endswith(".cmd"):
        shape = shape[:-4]

    if shape == "declared":
        # An honest length, past the limit. The one shape a length-based guard
        # can refuse before a single byte of body arrives.
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % BIG)
        send_body(conn, BIG)
    elif shape == "chunked":
        # No length at all. Whatever the guard does here, it does after the
        # bytes have started landing.
        conn.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
        sent = 0
        while sent < BIG:
            conn.sendall(b"%x\r\n" % len(BLK) + BLK + b"\r\n")
            sent += len(BLK)
        conn.sendall(b"0\r\n\r\n")
    elif shape == "lying":
        # A small declared length and a large body. A guard that trusts the
        # header takes the header's word for it.
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1024\r\n\r\n")
        send_body(conn, BIG)
    elif shape == "eof":
        # Neither length nor chunking: the body is delimited by the close.
        conn.sendall(b"HTTP/1.1 200 OK\r\n\r\n")
        send_body(conn, BIG)
    elif shape == "dribble":
        # One byte a second, forever. Every per-read timeout is satisfied and
        # no total ever arrives.
        conn.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
        while True:
            conn.sendall(b"1\r\na\r\n")
            time.sleep(1)
    else:
        conn.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")


def handle(conn, root, stall):
    try:
        conn.settimeout(30)
        req = b""
        while b"\r\n\r\n" not in req:
            chunk = conn.recv(4096)
            if not chunk:
                return
            req += chunk
            if len(req) > 65536:
                return
        parts = req.split(b" ")
        if len(parts) < 2:
            return
        respond(conn, parts[1].decode("latin-1"), root, stall)
    except Exception:
        # A client that walks away mid-body is the expected outcome of three
        # of these five shapes, not an error worth reporting.
        pass
    finally:
        try:
            conn.close()
        except Exception:
            pass


def main():
    port = int(sys.argv[1])
    root = sys.argv[2] if len(sys.argv) > 2 else "."
    stall = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(16)
    sys.stdout.write("up\n")
    sys.stdout.flush()
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn, root, stall), daemon=True).start()


main()
