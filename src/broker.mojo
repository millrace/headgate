"""CapabilityBroker — the tiny allowlist the generated code may call.

Containment is enforced by the sandbox (sandbox.mojo); the broker is the
capability surface *inside* it. Generated code never gets raw file handles or
sockets — only these functions. Note who they serve: the CODE running locally,
not the remote model. Results stay local (the harness reads them back from the
scratch dir); they do NOT loop back to the remote model except via the
schema/synthetic path through the EgressGuard.

Keep this list minimal and capability-based — every entry is attack surface.
"""


struct Result(Movable):
    var json: String   # the code's output, written to the sandbox scratch dir

    def __init__(out self, var json: String):
        self.json = json^


struct CapabilityBroker(Movable):
    var allowed: List[String]   # e.g. ["read_table", "write_result", "log"]

    def __init__(out self, var allowed: List[String]):
        self.allowed = allowed^

    def permits(self, tool: String) -> Bool:
        for a in self.allowed:
            if a == tool:
                return True
        return False

    # The concrete capabilities (stubs — executed by the in-sandbox shim):
    def read_table(self, name: String, columns: List[String]) raises -> String:
        """Read scoped private data (read-only mount). TODO."""
        return String("")  # TODO

    def write_result(self, r: Result) raises:
        """Write to the scratch dir — the only writable path. TODO."""
        pass  # TODO

    def log(self, msg: String):
        """Captured locally; scrubbed by the EgressGuard before any reuse. TODO."""
        pass  # TODO
