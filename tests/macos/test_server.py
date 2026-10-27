#!/usr/bin/env python3
"""Tiny HTTP server for the download tests.

Serves files from a directory. With --no-range it ignores Range headers and
always answers 200 with the whole file, like majestic-web.mpsa.com sometimes
does. Without it, Range requests get a proper 206.

Usage: test_server.py <dir> <port> [--no-range]
"""
import http.server
import os
import re
import sys

ROOT, PORT = sys.argv[1], int(sys.argv[2])
NO_RANGE = "--no-range" in sys.argv


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = os.path.join(ROOT, os.path.basename(self.path.split("?")[0]))
        if not os.path.isfile(path):
            self.send_error(404)
            return
        size = os.path.getsize(path)
        start = 0
        match = re.match(r"bytes=(\d+)-", self.headers.get("Range", ""))
        if match and not NO_RANGE:
            start = int(match.group(1))
            if start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        else:
            self.send_response(200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(size - start))
        self.end_headers()
        try:
            with open(path, "rb") as f:
                f.seek(start)
                while chunk := f.read(1 << 16):
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client gave up, e.g. curl -C - after a 200

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
