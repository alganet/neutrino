# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: ISC
#
# httpserve.py - `python3 -m http.server`, minus the reverse DNS lookup.
#
# http.server's own server_bind is four lines, and one of them is
#
#     self.server_name = socket.getfqdn(host)
#
# a reverse lookup on the address it has just bound. Every caller in this
# repository binds 127.0.0.1 and passes it explicitly, so the lookup is asking
# the machine's resolvers what loopback is called. On macOS 15 and later that
# reaches mDNSResponder, and reaching mDNSResponder is what the system counts as
# looking for devices on the local network -- so the runner raises
#
#     Allow "Python" to find devices on local networks?
#
# with Don't Allow, Allow, and nobody on a runner to click either. It sat over
# every picture the macOS lanes took after the first fixture came up, in front
# of the screen recording alert in the netinstall lane's frames.
#
# The nag is the visible half. The other half is in nt_serve's own numbers,
# which have carried it for rounds: `polls=6 secs=36` on macOS against nothing
# on linux, thirty-six seconds per suite for six requests, in a loop that sleeps
# a tenth of a second between them. Six seconds a request is not a server slow
# to bind -- a socket that is not listening refuses instantly -- it is what the
# system charges a process it is holding a question about.
#
# What server_name feeds is the CGI environment, which nothing here serves. So
# the lookup goes and the address is kept as it was given. Everything else is
# http.server's: same handler, same threading server, same directory listing,
# same responses -- the fixtures that assert against its exact output are
# asserting against the same code.
#
# Usage is http.server's too, deliberately, so the call sites read the same:
#
#     python3 test/httpserve.py --bind 127.0.0.1 --directory DIR PORT

import argparse
import functools
import http.server
import os
import socketserver
import sys


class Server(http.server.ThreadingHTTPServer):
    # Threading, because `python -m http.server` is threading and one of this
    # suite's own fixtures holds a connection open on purpose. A serial server
    # would answer that one request forever and nothing after it.
    daemon_threads = True

    def server_bind(self):
        # socketserver's, not http.server's. The difference is the one line
        # this file exists to drop; the rest of what HTTPServer.server_bind
        # does is set the two attributes below from what it looked up.
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def main():
    parser = argparse.ArgumentParser()
    # Loopback by default and not every interface, which is the other direction
    # http.server's default points. Nothing here wants to be reachable from the
    # network the prompt is asking about.
    parser.add_argument("--bind", "-b", default="127.0.0.1")
    parser.add_argument("--directory", "-d", default=os.getcwd())
    parser.add_argument("port", nargs="?", type=int, default=8000)
    args = parser.parse_args()

    handler = functools.partial(
        http.server.SimpleHTTPRequestHandler, directory=args.directory
    )
    # To stderr, where http.server writes its own startup line, and where every
    # caller here is already pointing a log.
    sys.stderr.write(
        "httpserve.py: serving %s on http://%s:%d/\n"
        % (args.directory, args.bind, args.port)
    )
    sys.stderr.flush()
    with Server((args.bind, args.port), handler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
