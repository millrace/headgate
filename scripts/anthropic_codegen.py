#!/usr/bin/env python3
"""Interim Anthropic Messages API helper for headgate's RemoteClient.

Reads a prompt from the file given as argv[1], calls the Messages API, and prints
the generated code (markdown fences stripped) to stdout. Pure stdlib (urllib).

This is a TEMPORARY shim. The harness is Mojo; the plan is to do this call in
pure Mojo over flare + parse JSON with minja2 once the dependency/toolchain story
is settled (see transport.mojo). It exists so the real codegen path can be wired
and tested without blocking on that.

Env:
  ANTHROPIC_API_KEY  required
  HEADGATE_MODEL     model id (default: claude-sonnet-4-6)
  ANTHROPIC_BASE_URL base url (default: https://api.anthropic.com/v1)

NOTE: the *prompt* has already passed headgate's EgressGuard before this runs.
"""
import json
import os
import sys
import urllib.request

SYSTEM = (
    "You are a code generator for the headgate privacy harness. You never see "
    "real data — only an aliased schema (col_0, col_1, ...) and synthetic samples. "
    "Write a single self-contained Mojo program with `def main() raises:` that "
    "reads the input CSV from the literal path `__DATA_CSV__`, computes the asked "
    "result, and prints it. Use only the Mojo standard library. Refer to columns "
    "by their aliases; the harness maps them back to real names locally. Output "
    "ONLY the Mojo code."
)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: anthropic_codegen.py <prompt_file>", file=sys.stderr)
        return 2
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        print("ANTHROPIC_API_KEY not set", file=sys.stderr)
        return 1

    with open(sys.argv[1], "r") as f:
        prompt = f.read()

    base = os.environ.get("ANTHROPIC_BASE_URL", "https://api.anthropic.com/v1")
    model = os.environ.get("HEADGATE_MODEL", "claude-sonnet-4-6")
    body = json.dumps({
        "model": model,
        "max_tokens": 2048,
        "system": SYSTEM,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()

    req = urllib.request.Request(
        base.rstrip("/") + "/messages",
        data=body,
        headers={
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        data = json.load(r)

    text = "".join(b.get("text", "") for b in data.get("content", []))

    # Strip a single ```...``` fence if present.
    if "```" in text:
        parts = text.split("```")
        if len(parts) >= 2:
            block = parts[1]
            nl = block.find("\n")
            text = block[nl + 1:] if nl != -1 else block

    sys.stdout.write(text.strip() + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
