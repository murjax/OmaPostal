#!/usr/bin/env python3
"""Minimal HTTP test server for http-send tests.

Usage: echo_server.py <port>

Routes:
  /echo         -> 200, header X-Test: yes, JSON body {method, path, headers, body}
                (path includes the query string)
  /status/<n>   -> status <n>, empty body
  /redirect     -> 302 Location: /echo
  /sleep/<n>    -> waits <n> seconds, then 200 (for cancellation tests)
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _handle(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""

        route = urlparse(self.path).path

        if route == "/echo":
            payload = json.dumps({
                "method": self.command,
                "path": self.path,
                "headers": dict(self.headers.items()),
                "body": body,
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("X-Test", "yes")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if route.startswith("/status/"):
            code = int(route.rsplit("/", 1)[-1])
            self.send_response(code)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if route.startswith("/sleep/"):
            time.sleep(float(route.rsplit("/", 1)[-1]))
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if route == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/echo")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_PATCH = _handle
    do_DELETE = _handle


if __name__ == "__main__":
    port = int(sys.argv[1])
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.serve_forever()
