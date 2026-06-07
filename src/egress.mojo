"""EgressGuard — the single outbound chokepoint toward the remote model.

headgate's CONFIDENTIALITY guarantee lives here. Every payload bound for the
remote (frontier) model passes through `check()` before it reaches the network
transport (transport.mojo). Nothing leaves the machine without clearing this gate.

For the careful-SaaS threat model (PRIOR-ART.md) the guard is a cheap, automatic
accident-catcher — not an adversary-proof filter:

  1. canary tripwire   — tokens seeded ONLY into the real private data. One on the
                         outbound path means the synthetic/real separation broke
                         upstream: hard fail.
  2. fingerprint trip  — fingerprints of real data values; a match means real data
                         is about to leave: hard fail.
  3. redaction         — a best-effort PII scrub applied to whatever survives.

Fails CLOSED: any tripwire raises, and the caller (transport) MUST abort the send.

This is the pi `pi-ai` lesson applied (PRIOR-ART.md): isolate transport in one
layer so there is exactly one place to enforce data-egress policy.
"""


def _contains(haystack: String, needle: String) -> Bool:
    """Substring test. TODO: replace with an n-gram / normalized-fingerprint index
    so reformatting (whitespace, casing, base64) can't slip a value past."""
    return haystack.find(needle) != -1


def _redact_pii(var payload: String) -> String:
    """Best-effort scrub of obvious PII shapes (emails, SSNs, long digit runs).
    Belt-and-suspenders behind the tripwires. TODO: real patterns."""
    return payload^


struct EgressGuard(Movable):
    var fingerprints: List[String]  # fingerprints of real-data spans
    var canaries: List[String]      # tokens that exist ONLY in the real data

    def __init__(out self, var fingerprints: List[String], var canaries: List[String]):
        self.fingerprints = fingerprints^
        self.canaries = canaries^

    def check(self, payload: String) raises -> String:
        """Return a redaction-scrubbed payload safe to send, or raise. Fails closed."""
        for c in self.canaries:
            if _contains(payload, c):
                raise Error(
                    "EgressBlocked: canary token on outbound path — real data"
                    " leaked into a remote-bound payload upstream of the guard"
                )
        for f in self.fingerprints:
            if _contains(payload, f):
                raise Error("EgressBlocked: real-data fingerprint on outbound path")
        return _redact_pii(payload.copy())
