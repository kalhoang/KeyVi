# SPDX-License-Identifier: GPL-3.0-or-later
"""Local HTTPS feed of scripts/vm/upgrade-test.sh (QA-R40, spec/02-platform.md 13.5 and 13.7).

Serves the run's appcast, update archive and release-notes page from one folder over HTTPS on the loopback
addresses, with a certificate issued by a throwaway CA that only the disposable VM trusts. The VM's /etc/hosts maps
the production site host to these addresses, so the release build under test fetches its own, unchanged feed URL
(SUFeedURL) from here. Every request is appended to a JSON lines log: time, client, method, path, status, size, Host
header and user agent. Runs INSIDE the VM only (as root, for ports 443 and 53); it refuses a real Mac.

With --dns-host HOST it also answers DNS for HOST on the loopback addresses, port 53 (the guest points
/etc/resolver/HOST at it): A is 127.0.0.1, AAAA is ::1 and every other type (the HTTPS record above all) has no
answer. /etc/hosts covers only A and AAAA, and on 2026-11-23 the real HTTPS record (alpn h3, ipv4hint) made the
release build download the archive from the production host over HTTP/3, past the local feed. Every query is logged.

Usage: python3 -I local-feed-server.py --root DIR --cert PEM --key PEM --log FILE [--port N]
       [--bind ADDRESS]... [--dns-host HOST] [--pid-file FILE]
"""
from __future__ import annotations

import argparse
import functools
import json
import os
import signal
import socket
import socketserver
import ssl
import struct
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
    """Serves the feed folder and logs one line per request once its status and size are known."""

    log_lock = threading.Lock()
    log_path = ""

    def send_response(self, code, message=None):  # noqa: D102 (http.server API)
        self.status = int(code)
        super().send_response(code, message)

    def send_header(self, keyword, value):  # noqa: D102 (http.server API)
        if keyword.lower() == "content-length":
            self.content_length = int(value)
        super().send_header(keyword, value)

    def log_request(self, code="-", size="-"):  # noqa: D102 (http.server API): logged in write_log instead
        pass

    def handle_request(self, method):
        self.status, self.content_length = None, None
        method()
        self.write_log()

    def do_GET(self):  # noqa: N802 (http.server API)
        self.handle_request(super().do_GET)

    def do_HEAD(self):  # noqa: N802 (http.server API)
        self.handle_request(super().do_HEAD)

    def write_log(self):
        record = {
            "at": time.time(),
            "client": self.client_address[0],
            "method": self.command,
            "path": self.path,
            "status": self.status,
            "size": self.content_length,
            "host": self.headers.get("Host", "") if self.headers else "",
            "userAgent": self.headers.get("User-Agent", "") if self.headers else "",
        }
        with self.log_lock, open(self.log_path, "a", encoding="utf-8") as log:
            log.write(json.dumps(record, sort_keys=True) + "\n")

    def log_message(self, format, *args):  # noqa: A002 (http.server API); errors go to stderr
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))


DNS_TYPES = {1: "A", 28: "AAAA", 64: "SVCB", 65: "HTTPS"}


def dns_reply(query: bytes, host: str) -> tuple:
    """(reply, name, type, answers) for one DNS query: A/AAAA of HOST on loopback, nothing for any other type,
    NXDOMAIN for any other name. (b"", "", 0, 0) for a packet that is not a query."""
    if len(query) < 17 or query[2] & 0x80:
        return b"", "", 0, 0
    ident, flags = struct.unpack(">HH", query[:4])
    index, labels = 12, []
    while index < len(query) and query[index]:
        length = query[index]
        labels.append(query[index + 1:index + 1 + length].decode("ascii", "replace"))
        index += 1 + length
    index += 1
    if index + 4 > len(query):
        return b"", "", 0, 0
    qtype, _qclass = struct.unpack(">HH", query[index:index + 4])
    question = query[12:index + 4]
    name = ".".join(labels).lower().rstrip(".")
    answer, rcode = b"", 0
    if name != host:
        rcode = 3
    elif qtype in (1, 28):
        family, address = (socket.AF_INET, "127.0.0.1") if qtype == 1 else (socket.AF_INET6, "::1")
        rdata = socket.inet_pton(family, address)
        answer = struct.pack(">HHHIH", 0xC00C, qtype, 1, 30, len(rdata)) + rdata
    reply_flags = 0x8000 | 0x0400 | (flags & 0x0100) | 0x0080 | rcode
    header = struct.pack(">HHHHHH", ident, reply_flags, 1, 1 if answer else 0, 0, 0)
    return header + question + answer, name, qtype, 1 if answer else 0


def make_dns_server(address: str, host: str, log_path: str):
    family = socket.AF_INET6 if ":" in address else socket.AF_INET

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            data, sock = self.request
            reply, name, qtype, answers = dns_reply(data, host)
            if not reply:
                return
            sock.sendto(reply, self.client_address)
            record = {"at": time.time(), "kind": "dns", "client": self.client_address[0], "name": name,
                      "type": DNS_TYPES.get(qtype, str(qtype)), "answers": answers}
            with FeedHandler.log_lock, open(log_path, "a", encoding="utf-8") as log:
                log.write(json.dumps(record, sort_keys=True) + "\n")

    class Server(socketserver.ThreadingUDPServer):
        address_family = family
        daemon_threads = True

    return Server((address, 53), Handler)


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
    parser.add_argument("--dns-host")
    parser.add_argument("--pid-file")
    args = parser.parse_args(argv)
    binds = args.bind or ["127.0.0.1", "::1"]
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)
    FeedHandler.log_path = args.log
    handler = functools.partial(FeedHandler, directory=args.root)
    servers = [make_server(address, args.port, handler, context) for address in binds]
    if args.dns_host:
        servers += [make_dns_server(address, args.dns_host.lower(), args.log) for address in binds]
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
