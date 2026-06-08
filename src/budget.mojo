"""Budget — a token budget for EXTERNAL (remote frontier model) API calls.

When the budget is depleted, the orchestrator routes code generation + fixes to
the LOCAL model instead (trusted, free, lower quality) — graceful degradation
rather than unbounded spend. Tokens are charged from the Anthropic response's
`usage` (input + output); the mock path estimates from prompt size.

Semantics of `limit` (HEADGATE_REMOTE_TOKEN_BUDGET):
  < 0  → unlimited (never depleted) — the default / today's behavior
  = 0  → always-local (depleted from the start)
  > 0  → N-token budget, then local
"""


struct Budget(Movable, Copyable):
    var limit: Int    # token budget; <0 unlimited, 0 always-local, >0 N tokens
    var spent: Int

    def __init__(out self, limit: Int):
        self.limit = limit
        self.spent = 0

    def depleted(self) -> Bool:
        """True once the external budget is used up (so route to local)."""
        return self.limit >= 0 and self.spent >= self.limit

    def remaining(self) -> Int:
        """Tokens left, or -1 for unlimited."""
        if self.limit < 0:
            return -1
        var r = self.limit - self.spent
        return r if r > 0 else 0

    def charge(mut self, tokens: Int):
        self.spent += tokens


def parse_budget(s: String) -> Int:
    """Parse an integer budget (e.g. from env). Accepts an optional leading '-';
    returns -1 (unlimited) on empty/invalid input."""
    var n = 0
    var neg = False
    var i = 0
    var any = False
    for cp in s.codepoints():
        var v = Int(cp)
        if i == 0 and v == 45:        # leading '-'
            neg = True
            i += 1
            continue
        if v < 48 or v > 57:
            return -1
        n = n * 10 + (v - 48)
        any = True
        i += 1
    if not any:
        return -1
    return -n if neg else n
