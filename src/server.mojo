"""server — headgate over HTTP (flare). The local backend for headgate-web (web/).

Runs the SAME vault orchestrator the CLI does, on localhost:10000, behind one route:

    POST /chat   { "message": <question> }  ->  { "reply": <answer> }
    GET  /health
    OPTIONS *    (CORS preflight, so the browser app on :5173 can call us)

Single-threaded reactor — one task in flight at a time. The orchestrator lives
in a heap `HeadgateState` reached through a pointer so the borrowed-self handler
can still run `mut` codegen (mirrors inference-server/server.mojo).

VAULT-ONLY: `/chat` always runs the private-vault codegen loop
(`run_vault_task`) over the resolved vault dir. There is no CSV mode.

    pixi run serve-web        # listens on 127.0.0.1:10000
"""

from std.memory import alloc

from flare.prelude import *
from flare.http import Handler

from settings import load_config
from wiring import build_vault_orchestrator
from orchestrator import Orchestrator
from vaultcfg import vault_dir as resolve_vault_dir
from json import loads

comptime PORT = 10000


struct HeadgateState(Movable):
    """The vault orchestrator + vault dir, loaded once and reached by the
    (borrowed-self) handler through a pointer so `run_vault_task` can still take
    `mut self`. `/chat` always runs `run_vault_task` over `vault_dir`."""

    var orch: Orchestrator
    var vault_dir: String

    def __init__(out self, var orch: Orchestrator, var vault_dir: String):
        self.orch = orch^
        self.vault_dir = vault_dir^


def _json_escape(s: String) -> String:
    """Quote + escape `s` as a JSON string (control chars dropped to spaces)."""
    var out = String('"')
    for cp in s.codepoints():
        var c = Int(cp)
        if c == 34:
            out += '\\"'
        elif c == 92:
            out += "\\\\"
        elif c == 10:
            out += "\\n"
        elif c == 13:
            out += "\\r"
        elif c == 9:
            out += "\\t"
        elif c < 32:
            out += " "
        else:
            out += chr(c)
    out += '"'
    return out


def _extract_message(body: String) -> String:
    """Pull `message` out of a `{ "message": ... }` body (empty on any failure)."""
    try:
        var j = loads(body)
        return j["message"].string_value()
    except:
        return String("")


def _content_type(path: String) -> String:
    """Guess a Content-Type from the file extension (the few Vite emits)."""
    if path.find(".js") != -1:
        return String("application/javascript; charset=utf-8")
    if path.find(".css") != -1:
        return String("text/css; charset=utf-8")
    if path.find(".svg") != -1:
        return String("image/svg+xml")
    if path.find(".html") != -1:
        return String("text/html; charset=utf-8")
    return String("application/octet-stream")


def _serve_file(path: String, content_type: String) raises -> Response:
    """Read a file under web/dist and return it (404 if missing)."""
    var content: String
    try:
        with open(path, "r") as f:
            content = f.read()
    except:
        return not_found(path)
    var r = ok(content)
    try:
        r.headers.set("Content-Type", content_type)
    except:
        pass
    return r^


def _cors(var resp: Response) -> Response:
    """Allow the local web app (a different origin/port) to call this API."""
    try:
        resp.headers.set("Access-Control-Allow-Origin", "*")
        resp.headers.set("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        resp.headers.set("Access-Control-Allow-Headers", "Content-Type")
    except:
        pass
    return resp^


@fieldwise_init
struct Api(Handler, Copyable, Movable):
    var st: UnsafePointer[HeadgateState, MutExternalOrigin]

    def serve(self, req: Request) raises -> Response:
        var path = req.url
        # CORS preflight (compare the raw method string — no Method.OPTIONS dep).
        if req.method == "OPTIONS":
            return _cors(Response(status=204, reason="No Content"))
        if req.method == Method.POST and path == "/chat":
            return self.handle_chat(req)
        if path == "/health":
            return _cors(ok("headgate ok"))
        # Static web UI — same-origin in production (Vite serves it in dev).
        # Reject path traversal before mapping under web/dist.
        if path.find("..") == -1:
            if path == "/" or path == "/index.html":
                return _serve_file("web/dist/index.html", "text/html; charset=utf-8")
            if path == "/favicon.svg":
                return _serve_file("web/dist/favicon.svg", "image/svg+xml")
            if path.find("/assets/") == 0:
                return _serve_file("web/dist" + path, _content_type(path))
        return _cors(not_found(path))

    def handle_chat(self, req: Request) raises -> Response:
        ref s = self.st[]
        var msg = _extract_message(req.text())
        if msg == "":
            return _cors(bad_request('{"reply":"(empty message)"}'))
        print("  chat: ", msg, sep="")
        var reply: String
        try:
            # VAULT-ONLY: always the private-vault codegen loop over the vault dir.
            reply = s.orch.run_vault_task(msg, s.vault_dir.copy())
        except e:
            reply = String("error: ") + String(e)
        return _cors(ok_json('{"reply":' + _json_escape(reply) + "}"))


def main() raises:
    var cfg = load_config()

    # VAULT-ONLY: build the vault orchestrator over the resolved vault dir
    # (HEADGATE_VAULT_DIR / $DACULAR_VAULT / $HEADGATE_DATA / ~/dacular) and route
    # /chat to run_vault_task.
    var vault_dir = resolve_vault_dir()
    print("headgate VAULT mode — vault dir: " + vault_dir)
    var orch = build_vault_orchestrator(cfg, vault_dir)

    var st = HeadgateState(orch^, vault_dir^)
    var sp = alloc[HeadgateState](1)
    sp.init_pointee_move(st^)
    var api = Api(sp)

    print("headgate serving on http://127.0.0.1:", PORT, "  (flare)", sep="")
    print('  POST /chat   { "message": ... } -> { "reply": ... }')
    var srv = HttpServer.bind(SocketAddr.localhost(UInt16(PORT)))
    srv.serve(api^)
