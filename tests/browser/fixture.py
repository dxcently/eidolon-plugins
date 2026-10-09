#!/usr/bin/env python3
"""The live smoke's pages, served on loopback: no external assets, nothing fetched from anywhere
but 127.0.0.1, and nothing but these two inert pages exists.

    python3 tests/browser/fixture.py --port 8098

`/` carries one link named "next" to `/next`, whose text is distinct so the smoke can assert the
navigation happened.
"""
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer

HOME = b"""<!doctype html><html><head><title>smoke home</title></head><body>
<h1>smoke home</h1><p>the home page of the smoke</p><a href="/next">next</a>
</body></html>"""

NEXT = b"""<!doctype html><html><head><title>next page</title></head><body>
<h1>next page</h1><p>the second page of the smoke</p>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):  # quiet
        pass

    def do_GET(self):
        body = NEXT if self.path.startswith("/next") else HOME
        self.send_response(200)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8098)
    args = ap.parse_args()
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
