#!/usr/bin/env python3
"""Canned OpenAI /chat/completions server that returns a VALID Mojo program — for
verifying the budget-depleted -> local-model codegen route (test only).

Returns a row-counter program reading __DATA_CSV__ (the orchestrator injects the
real path), so the local-codegen path produces runnable code. Listens on :8799.
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

PROGRAM = (
    "def main() raises:\n"
    "    var text: String\n"
    '    with open("__DATA_CSV__", "r") as f:\n'
    "        text = f.read()\n"
    '    var lines = text.split("\\n")\n'
    "    var count = 0\n"
    "    for i in range(1, len(lines)):\n"
    "        var ln = String(String(lines[i]).strip())\n"
    "        if ln.byte_length() > 0:\n"
    "            count += 1\n"
    '    print("ROW_COUNT=", count)\n'
)


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        _ = self.rfile.read(n)
        payload = json.dumps({
            "choices": [{"message": {"role": "assistant", "content": PROGRAM}}]
        }).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8799), H).serve_forever()
