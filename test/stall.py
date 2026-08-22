# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# stall.py - A socket that accepts and then says nothing, ever.
#
# test/neutrinoearly.js navigates before its own load has finished, which is the
# window the gjs navigation guard used to leave open. That window looks closed
# on a document with nothing to fetch: WebKitGTK delivers the policy decision on
# a later turn of the main loop, and the load finishes first and arms the guard
# in between. It is a race, and a hostile page wins it by keeping its own load
# pending -- so the test has to do the same, or it asserts against a race
# instead of against the guard.
#
# Connection refused is not enough: that finishes, quickly. This accepts the
# connection and holds it open without answering, which is the one thing a page
# can arrange that keeps a subresource outstanding for as long as it likes.

import socket
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", PORT))
server.listen(64)
sys.stderr.write("stall.py: holding connections on 127.0.0.1:%d\n" % PORT)
sys.stderr.flush()

# Kept in a list rather than dropped, because a socket that goes out of scope is
# closed, and a closed socket is a subresource that finished.
held = []
while True:
    conn, _ = server.accept()
    held.append(conn)
