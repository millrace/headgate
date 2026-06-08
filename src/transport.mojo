"""Transport — HTTP to the two models, with the EgressGuard wired into the remote path.

This is headgate's `pi-ai`-equivalent layer (PRIOR-ART.md): the one place network
I/O happens, so the one place egress policy is enforced.

Two clients, deliberately asymmetric:
  - LocalClient  -> the on-device model via `inference-server` (mojo-backend).
                    Sees the REAL private data. No egress guard: it never leaves
                    the machine (127.0.0.1).
  - RemoteClient -> the frontier model. EVERY message is run through the
                    EgressGuard before it touches the socket. trusted-local vs
                    untrusted-remote.

RemoteClient.codegen has two paths:
  - MOCK (default; when ANTHROPIC_API_KEY is unset or HEADGATE_MOCK is set):
    returns a canned generated program so the whole pipeline runs offline.
  - REAL: shells to scripts/anthropic_codegen.py (curl-free; stdlib urllib) for
    the Anthropic Messages API call. INTERIM — TODO: flare HTTP + minja2 JSON in
    pure Mojo once the dependency story is settled.
"""

from std.os import getenv
from std.ffi import external_call, c_int
from egress import EgressGuard


def _shell(var cmd: String) -> Int:
    return Int(external_call["system", c_int](cmd.as_c_string_slice()))


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _write(path: String, s: String) raises:
    with open(path, "w") as f:
        f.write(s)


def _mock_program() -> String:
    """A canned 'generated' program: count non-empty data rows in the CSV at the
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


struct ChatMessage(Movable, Copyable):
    var role: String     # "system" | "user" | "assistant"
    var content: String

    def __init__(out self, var role: String, var content: String):
        self.role = role^
        self.content = content^


struct LocalClient(Movable):
    """Local model via inference-server. baseURL is the OpenAI seam (README.md)."""
    var base_url: String

    def __init__(out self, var base_url: String):
        self.base_url = base_url^

    def chat(self, messages: List[ChatMessage]) raises -> String:
        """POST /chat/completions to the local server. No egress guard — local
        only. TODO: flare HttpClient call + parse."""
        return String("")  # TODO


struct RemoteClient(Movable):
    """Frontier model. The guard gates the outbound path — enforced here, not left
    to callers, so it cannot be bypassed."""
    var base_url: String
    var api_key: String
    var guard: EgressGuard

    def __init__(out self, var base_url: String, var api_key: String, var guard: EgressGuard):
        self.base_url = base_url^
        self.api_key = api_key^
        self.guard = guard^

    def codegen(self, messages: List[ChatMessage]) raises -> String:
        """Ask the remote model to write code. Each message's content must clear
        the EgressGuard first (fails closed: if the guard raises, nothing is sent).
        Returns generated code."""
        var prompt = String("")
        for m in messages:
            var checked = self.guard.check(m.content)   # raises -> aborts send
            prompt += m.role + ": " + checked + "\n"

        var key = getenv("ANTHROPIC_API_KEY", "")
        if getenv("HEADGATE_MOCK", "") != "" or key == "":
            return _mock_program()
        return self._anthropic(prompt)

    def _anthropic(self, prompt: String) raises -> String:
        """INTERIM real path: write the (guard-cleared) prompt to a temp file and
        run the python helper, which does the Messages API call + JSON parse +
        fence-strip and prints the generated code. Untested in this env (no key).
        TODO: replace with flare HTTP + minja2 JSON in pure Mojo."""
        var tmp = getenv("TMPDIR", "/tmp/")
        var prompt_file = tmp + "hg_prompt.txt"
        var resp_file = tmp + "hg_resp.txt"
        _write(prompt_file, prompt)
        var cmd = String("python3 scripts/anthropic_codegen.py '") + prompt_file
        cmd += String("' > '") + resp_file + "' 2>/dev/null"
        _ = _shell(cmd)
        try:
            return _read(resp_file)
        except:
            return String("")
