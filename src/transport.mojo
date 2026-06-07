"""Transport — HTTP to the two models, with the EgressGuard wired into the remote path.

This is headgate's `pi-ai`-equivalent layer (PRIOR-ART.md): the one place network
I/O happens, so the one place egress policy is enforced. Both clients speak the
OpenAI-compatible chat API over flare (millrace's own Mojo HTTP stack).

Two clients, deliberately asymmetric:
  - LocalClient  -> the on-device model via `inference-server` (mojo-backend).
                    Sees the REAL private data. No egress guard: it never leaves
                    the machine (127.0.0.1).
  - RemoteClient -> the frontier model. EVERY message is run through the
                    EgressGuard before it touches the socket. This asymmetry is
                    the whole point: trusted-local vs untrusted-remote.
"""

from egress import EgressGuard
# from flare.http.client import HttpClient   # TODO: wire flare transport


struct ChatMessage(Movable, Copyable):
    var role: String     # "system" | "user" | "assistant"
    var content: String

    def __init__(out self, var role: String, var content: String):
        self.role = role^
        self.content = content^


struct LocalClient(Movable):
    """Local model via inference-server. baseURL is the OpenAI seam (README.md)."""
    var base_url: String   # e.g. http://127.0.0.1:8000/v1

    def __init__(out self, var base_url: String):
        self.base_url = base_url^

    def chat(self, messages: List[ChatMessage]) raises -> String:
        """POST /chat/completions to the local server. No egress guard — local
        only. TODO: flare HttpClient call + parse."""
        return String("")  # TODO


struct RemoteClient(Movable):
    """Frontier model. The guard gates the outbound path; this is enforced here,
    not left to callers, so there is no way to bypass it."""
    var base_url: String
    var api_key: String
    var guard: EgressGuard

    def __init__(out self, var base_url: String, var api_key: String, var guard: EgressGuard):
        self.base_url = base_url^
        self.api_key = api_key^
        self.guard = guard^

    def codegen(self, messages: List[ChatMessage]) raises -> String:
        """Ask the remote model to write code. Each message's content must clear
        the EgressGuard before it can be serialized to the wire. Fails closed:
        if the guard raises, nothing is sent."""
        var safe = List[ChatMessage]()
        for m in messages:
            var checked = self.guard.check(m.content)   # raises -> aborts send
            safe.append(ChatMessage(m.role.copy(), checked^))
        # TODO: flare HttpClient POST to {base_url}/chat/completions with `safe`.
        _ = safe
        return String("")  # TODO
