"""Transport — HTTP to the two models over flare, with the EgressGuard on the remote path.

headgate's `pi-ai`-equivalent layer (PRIOR-ART.md): the one place network I/O
happens, so the one place egress policy is enforced. Now pure Mojo over flare's
HttpClient (no curl/python), parsing responses with flare's `Response.json()`.

Two clients, deliberately asymmetric:
  - LocalClient  -> the on-device model via `inference-server` (mojo-backend),
                    OpenAI /chat/completions over plain HTTP (127.0.0.1). No egress
                    guard: it never leaves the machine.
  - RemoteClient -> the frontier model (Anthropic Messages API, HTTPS). EVERY
                    message clears the EgressGuard before it touches the socket.

MOCK path: when ANTHROPIC_API_KEY is unset or HEADGATE_MOCK is set, codegen returns
a canned program so the pipeline runs offline.
"""

from std.os import getenv
from flare.http import HttpClient, Request
from egress import EgressGuard


# ── helpers ──────────────────────────────────────────────────────────────────

def _replace_all(s: String, old: String, new: String) raises -> String:
    var parts = s.split(old)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += new
        out += String(parts[i])
    return out


def _json_escape(s: String) raises -> String:
    var o = _replace_all(s, String("\\"), String("\\\\"))
    o = _replace_all(o, String('"'), String('\\"'))
    o = _replace_all(o, String("\n"), String("\\n"))
    o = _replace_all(o, String("\r"), String("\\r"))
    o = _replace_all(o, String("\t"), String("\\t"))
    return o


def _strip_fences(var s: String) raises -> String:
    """If the model wrapped code in a ```...``` block, return the inside (minus
    the optional leading language tag). String has no slicing, so split + rejoin."""
    if s.find("```") == -1:
        return s^
    var parts = s.split("```")
    if len(parts) < 2:
        return s^
    var block = String(parts[1])
    if block.find("\n") == -1:
        return block^
    var lines = block.split("\n")
    var out = String("")
    for i in range(1, len(lines)):   # drop the language-tag line
        if i > 1:
            out += "\n"
        out += String(lines[i])
    return out^


def _mock_program() -> String:
    """Canned 'generated' program: count non-empty data rows in the CSV at the
    `__DATA_CSV__` placeholder (the orchestrator injects the real path)."""
    var s = String("def main() raises:\n")
    s += "    var text: String\n"
    s += '    with open("__DATA_CSV__", "r") as f:\n'
    s += "        text = f.read()\n"
    s += '    var lines = text.split("\\n")\n'
    s += "    var count = 0\n"
    s += "    for i in range(1, len(lines)):\n"
    s += "        var ln = String(String(lines[i]).strip())\n"
    s += "        if ln.byte_length() > 0:\n"
    s += "            count += 1\n"
    s += '    print("ROW_COUNT=", count)\n'
    return s


def _codegen_system() -> String:
    """System prompt for the remote model. The model's training predates current
    Mojo, so it emits removed syntax (`let`, `fn`, `alias`, `from pathlib import`).
    Teach the current dialect + give a known-good example to pattern-match. (Static,
    no private data — safe to send.) The durable fix is the compile-feedback loop;
    this is the first line."""
    var s = String(
        "You generate ONE self-contained Mojo program. Output ONLY Mojo code —"
        " no prose, no markdown fences.\n\n"
    )
    s += "Mojo has CHANGED since your training data. Follow these rules EXACTLY:\n"
    s += "- Use `def`, never `fn` (removed). `def` does NOT imply raising; write `def main() raises:`.\n"
    s += "- Use `var`, never `let` (removed).\n"
    s += "- Use `comptime`, never `alias` (removed).\n"
    s += "- Stdlib imports need the `std.` prefix (e.g. `from std.os import ...`). Avoid pathlib — read files with `open()`.\n"
    s += "- No String slicing (`s[a:b]` is invalid). Use `s.split(sep)` and wrap parts with `String(...)`.\n"
    s += "- `len(x)` for lists; `s.byte_length()` for a String's length; `String(s.strip())` to trim.\n\n"
    s += (
        "TASK: read the CSV at the literal path __DATA_CSV__ (first row is a"
        " header), compute the requested result, and `print` it. Refer to columns"
        " by their aliases (col_0, col_1, ...).\n\n"
    )
    s += "COMPLETE VALID EXAMPLE — match this exact style and API:\n"
    s += _mock_program()
    return s


struct ChatMessage(Movable, Copyable):
    var role: String     # "system" | "user" | "assistant"
    var content: String

    def __init__(out self, var role: String, var content: String):
        self.role = role^
        self.content = content^


struct LocalClient(Movable):
    """Local model via inference-server, OpenAI /chat/completions over plain HTTP."""
    var base_url: String   # e.g. http://127.0.0.1:8000/v1

    def __init__(out self, var base_url: String):
        self.base_url = base_url^

    def chat(self, messages: List[ChatMessage]) raises -> String:
        """POST the messages and return the assistant content. Local only — no
        egress guard. Requires inference-server running."""
        var model = getenv("HEADGATE_LOCAL_MODEL", "local")
        var body = String('{"model":"') + model + '","messages":['
        for i in range(len(messages)):
            if i > 0:
                body += ","
            body += '{"role":"' + messages[i].role
            body += '","content":"' + _json_escape(messages[i].content) + '"}'
        body += "]}"

        var req = Request(
            method="POST",
            url=self.base_url + "/chat/completions",
            body=List[UInt8](body.as_bytes()),
        )
        req.headers.set("content-type", "application/json")
        var client = HttpClient()
        var resp = client.send(req)
        return resp.json()["choices"][0]["message"]["content"].string_value()

    def codegen(self, messages: List[ChatMessage]) raises -> String:
        """Local model AS code generator — used when the remote budget is depleted.
        Trusted + free; no egress guard. Prepends the current-Mojo system prompt so
        the local model writes valid Mojo; strips code fences."""
        var msgs = List[ChatMessage]()
        msgs.append(ChatMessage(String("system"), _codegen_system()))
        for m in messages:
            msgs.append(ChatMessage(m.role.copy(), m.content.copy()))
        return _strip_fences(self.chat(msgs))

    def fix_code(self, code: String, errors: String) raises -> String:
        """Local model fixes failing code — used when the remote budget is depleted."""
        var prompt = String(
            "The Mojo program below FAILED. Fix it and output ONLY the corrected,"
            " complete Mojo program.\n\nERRORS:\n"
        ) + errors + "\n\nPROGRAM:\n" + code
        var msgs = List[ChatMessage]()
        msgs.append(ChatMessage(String("system"), _codegen_system()))
        msgs.append(ChatMessage(String("user"), prompt))
        return _strip_fences(self.chat(msgs))


struct Generated(Movable):
    """A code-generation result: the code + the token cost (from the remote API's
    usage; 0 for mock). The orchestrator charges the Budget by `tokens`."""
    var code: String
    var tokens: Int

    def __init__(out self, var code: String, tokens: Int):
        self.code = code^
        self.tokens = tokens


struct RemoteClient(Movable):
    """Frontier model (Anthropic Messages API, HTTPS). The guard gates the outbound
    path — enforced here, not left to callers, so it cannot be bypassed."""
    var base_url: String   # e.g. https://api.anthropic.com/v1
    var api_key: String
    var guard: EgressGuard

    def __init__(out self, var base_url: String, var api_key: String, var guard: EgressGuard):
        self.base_url = base_url^
        self.api_key = api_key^
        self.guard = guard^

    def codegen(self, messages: List[ChatMessage]) raises -> Generated:
        """Each message must clear the EgressGuard first (fails closed). Returns the
        generated code + token cost. MOCK unless a real key is present."""
        var prompt = String("")
        for m in messages:
            var checked = self.guard.check(m.content)   # raises -> aborts send
            prompt += m.role + ": " + checked + "\n"

        var key = getenv("ANTHROPIC_API_KEY", "")
        if getenv("HEADGATE_MOCK", "") != "" or key == "":
            return Generated(_mock_program(), prompt.byte_length() // 4 + 300)
        return self._anthropic(prompt, key)

    def fix_code(self, code: String, errors: String) raises -> Generated:
        """Ask the remote model to fix code that failed (compile or runtime).
        Operates ONLY on ALIASED code + aliased errors (no real data/names) — still
        routed through the EgressGuard (fails closed). Offline (mock / no key):
        returns the code unchanged at 0 cost."""
        var prompt = String(
            "The Mojo program below FAILED. Fix it and output ONLY the corrected,"
            " complete Mojo program.\n\nERRORS:\n"
        )
        prompt += errors + "\n\nPROGRAM:\n" + code
        var checked = self.guard.check(prompt)   # raises -> aborts the send
        var key = getenv("ANTHROPIC_API_KEY", "")
        if getenv("HEADGATE_MOCK", "") != "" or key == "":
            return Generated(code.copy(), 0)
        return self._anthropic(checked, key)

    def _anthropic(self, prompt: String, key: String) raises -> Generated:
        var sys = _codegen_system()
        var model = getenv("HEADGATE_MODEL", "claude-sonnet-4-6")
        var body = String('{"model":"') + model + '","max_tokens":2048,'
        body += '"system":"' + _json_escape(sys) + '",'
        body += '"messages":[{"role":"user","content":"' + _json_escape(prompt) + '"}]}'

        var req = Request(
            method="POST",
            url=self.base_url + "/messages",
            body=List[UInt8](body.as_bytes()),
        )
        req.headers.set("x-api-key", key)
        req.headers.set("anthropic-version", "2023-06-01")
        req.headers.set("content-type", "application/json")
        var client = HttpClient()
        var resp = client.send(req)
        var v = resp.json()
        var code = _strip_fences(v["content"][0]["text"].string_value())
        var toks: Int
        try:
            toks = Int(v["usage"]["input_tokens"].int_value()) + Int(
                v["usage"]["output_tokens"].int_value())
        except:
            toks = 0
        return Generated(code^, toks)
