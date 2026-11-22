# SPDX-License-Identifier: GPL-3.0-or-later
"""Local HTTPS feed of scripts/vm/upgrade-test.sh (QA-R40, spec/02-platform.md 13.5 and 13.7).

Serves the run's appcast, update archive and release-notes page from one folder over HTTPS on the loopback
addresses, with a certificate issued by a throwaway CA that only the disposable VM trusts. The VM's /etc/hosts maps
the production site host to these addresses, so the release build under test fetches its own, unchanged feed URL
(SUFeedURL) from here. Every request is appended to a JSON lines log: time, client, method, path, status, size, Host
header and user agent. Runs INSIDE the VM only (as root, for port 443); it refuses a real Mac.

Usage: python3 -I local-feed-server.py --root DIR --cert PEM --key PEM --log FILE [--port N]
       [--bind ADDRESS]... [--pid-file FILE]
"""
from __future__ import annotations

import argparse
import functools
import json
import os
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


def inside_virtual_machine() -> bool:
    try:
        out = subprocess.run(["/usr/sbin/sysctl", "-n", "kern.hv_vmm_present"], capture_output=True, text=True)
    except OSError:
        return False
    return out.stdout.strip() == "1"


class FeedHandler(SimpleHTTPRequestHandler):
    log_lock = threading.Lock()
    log_path = ""

    def log_request(self, code="-", size="-"):  # noqa: D102 (http.server API)
        record = {
            "at": time.time(),
            "client": self.client_address[0],
            "method": self.command,
            "path": self.path,
            "status": int(code) if str(code).isdigit() else str(code),
            "size": int(size) if str(size).isdigit() else None,
            "host": self.headers.get("Host", "") if self.headers else "",
            "userAgent": self.headers.get("User-Agent", "") if self.headers else "",
        }
        with self.log_lock, open(self.log_path, "a", encoding="utf-8") as log:
            log.write(json.dumps(record, sort_keys=True) + "\n")

    def log_message(self, format, *args):  # noqa: A002 (http.server API); errors go to stderr
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))


def make_server(address: str, port: int, handler, context: ssl.SSLContext) -> ThreadingHTTPServer:
    family = socket.AF_INET6 if ":" in address else socket.AF_INET

    class Server(ThreadingHTTPServer):
        address_family = family
        daemon_threads = True

    server = Server((address, port), handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    return server


def main(argv: list[str]) -> int:
    if not inside_virtual_machine():
        print("refusing: not inside a virtual machine", file=sys.stderr)
        return 3
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--port", type=int, default=443)
    parser.add_argument("--bind", action="append", default=[])
    parser.add_argument("--pid-file")
    args = parser.parse_args(argv)
    binds = args.bind or ["127.0.0.1", "::1"]
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)
    FeedHandler.log_path = args.log
    handler = functools.partial(FeedHandler, directory=args.root)
    servers = [make_server(address, args.port, handler, context) for address in binds]
    if args.pid_file:
        with open(args.pid_file, "w", encoding="utf-8") as pid_file:
            pid_file.write(str(os.getpid()))
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in servers]
    for thread in threads:
        thread.start()
    print("serving %s on %s port %d" % (args.root, ", ".join(binds), args.port), flush=True)
    while not stop.wait(1):
        pass
    for server in servers:
        server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
