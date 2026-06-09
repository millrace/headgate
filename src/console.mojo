"""console — minimal interactive terminal input for headgate's REPL.

Mojo's stdlib has no stdin reader. Reading fd 0 via libc `read(2)` clashes with
flare's own `external_call["read"]` declaration (same symbol, different
signature → a link error), so we read a byte at a time with `getchar(3)` — a
distinct symbol, no pointer args, no conflict. Prompts go out via `print(...,
flush=True)`. Used by the interactive task loop and the first-run "where is your
data?" prompt in headgate.mojo.

Line input only (no editing/history). Bytes are taken verbatim; non-ASCII input
is passed through byte-for-byte, which is fine for typed task prompts.
"""

from std.ffi import external_call, c_int


struct Line(Movable):
    """One line of input. `eof` is True when stdin closed (Ctrl-D) with nothing
    pending — the REPL's signal to stop."""
    var text: String
    var eof: Bool

    def __init__(out self, var text: String, eof: Bool):
        self.text = text^
        self.eof = eof


def read_line(prompt: String) -> Line:
    """Print `prompt`, then read one line from stdin. The returned text has no
    trailing newline. On a closed stdin before any byte, `eof` is True."""
    # flush=True so the prompt shows before the blocking read (print() buffers).
    print(prompt, end="", flush=True)
    var line = String("")
    var any = False
    while True:
        var c = Int(external_call["getchar", c_int]())
        if c < 0:  # EOF (-1)
            return Line(line^, not any)
        any = True
        if c == 10:  # '\n'
            return Line(line^, False)
        if c == 13:  # '\r' — swallow (CRLF terminals)
            continue
        line += chr(c)
