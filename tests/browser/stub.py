#!/usr/bin/env python3
"""A stand-in for the browser service, for smokes: the same wire, no Chromium, no page, no
network. It answers `/health`, and `/call` after checking the bearer token it was given.

    python3 tests/browser/stub.py --port 8099 --token-file /tmp/browser.token

The methods are the six the tools reach; the answers are canned so a smoke can assert them, and
a stale ref is refused the way the real service refuses one (a ref is good only until the page
changes). Nothing here fetches anything.
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = {"token": "", "url": "", "refs": {}, "opened": 0}


def answer(method, args):
    if method == "open":
        STATE["opened"] += 1
        STATE["url"] = str(args.get("url", ""))
        # A new page invalidates the old refs, exactly as the real service's does.
        STATE["refs"] = {"e1": "the only link"}
        return f"opened {STATE['url']} — 1 ref"
    if method == "snapshot":
        if not STATE["url"]:
            raise ValueError("nothing is open")
        return "url: %s\ntitle: smoken\n\n- main [ref=e1]:\n  - link \"next\" [ref=e1]" % STATE["url"]
    if method == "read":
        if not STATE["url"]:
            raise ValueError("nothing is open")
        return "this is the stub's page text"
    if method == "click":
        ref = str(args.get("ref", ""))
        if ref not in STATE["refs"]:
            raise ValueError(f"the ref `{ref}` is stale — take a new snapshot")
        return f"clicked {ref}"
    if method == "type":
        ref = str(args.get("ref", ""))
        if ref not in STATE["refs"]:
            raise ValueError(f"the ref `{ref}` is stale — take a new snapshot")
        return f"typed into {ref}"
    if method == "back":
        return "went back"
    if method == "state":
        return json.dumps({"url": STATE["url"], "opens": STATE["opened"]})
    raise ValueError(f"no such method `{method}`")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):  # quiet
        pass

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"chromium_installed": True, "status": "ok"})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        if auth != f"Bearer {STATE['token']}":
            self.reply(401, {"error": "no token, or the wrong one"})
            return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        try:
            result = answer(body.get("method", ""), body.get("args") or {})
            self.reply(200, {"ok": True, "result": result})
        except ValueError as e:
            self.reply(200, {"ok": False, "error": str(e)})

    def reply(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--token-file", required=True)
    args = ap.parse_args()
    with open(args.token_file) as f:
        STATE["token"] = f.read().strip()
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
