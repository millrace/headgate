"""sandbox-demo — drive the Sandbox slice end-to-end from Mojo and verify it.

Mirrors sandbox/spike.sh, but the profile rendering + exec now run through
src/sandbox.mojo (Mojo), not shell. `pixi run sandbox-demo`.

Sets up a throwaway ./demo layout, then runs three checks under the sandbox:
  - read in-scope data  -> allowed (and we print what it read, proving local read)
  - read out-of-scope   -> denied
  - network egress      -> denied
Exits non-zero if any check fails.
"""

from std.ffi import external_call, c_int
from sandbox import Sandbox, SandboxPolicy, RunResult


def _sh(var cmd: String) -> Int:
    return Int(external_call["system", c_int](cmd.as_c_string_slice()))


def _check(name: String, expect_allow: Bool, r: RunResult) -> Bool:
    var allowed = r.exit_code == 0
    var ok = allowed == expect_allow
    var tag = "[PASS]" if ok else "[FAIL]"
    var verb = "allowed" if allowed else "denied"
    var want = "allow" if expect_allow else "deny"
    print(tag, name, "->", verb, "(exit", r.exit_code, ", wanted", want + ")")
    return ok


def main() raises:
    # Throwaway demo layout (under the repo, which lives in $HOME — so the
    # out-of-scope dir is denied by the $HOME read-deny, while the data dir is
    # re-allowed: exactly the spike's logic).
    _ = _sh("rm -rf demo && mkdir -p demo/data demo/scratch demo/private")
    _ = _sh("printf 'PRIVATE-ROW: ssn=123-45-6789\\n' > demo/data/records.csv")
    _ = _sh("printf 'OUT-OF-SCOPE SECRET\\n' > demo/private/keys.txt")

    var policy = SandboxPolicy(String("demo/data"), String("demo/scratch"))
    var sb = Sandbox(policy^, String("sandbox/headgate.sb.template"))

    print("headgate sandbox-demo (Mojo-driven)\n")
    var all_ok = True

    # T1: in-scope read — allowed. Show what it read to prove local access works.
    var a1 = List[String]()
    a1.append(String("demo/data/records.csv"))
    var r1 = sb.run(String("/bin/cat"), a1)
    all_ok = _check(String("in-scope data read"), True, r1) and all_ok
    print("       (read back:", r1.output.strip(), ")")

    # T2: out-of-scope read — denied.
    var a2 = List[String]()
    a2.append(String("demo/private/keys.txt"))
    var r2 = sb.run(String("/bin/cat"), a2)
    all_ok = _check(String("out-of-scope read"), False, r2) and all_ok

    # T3: network egress — denied (the primary containment control).
    var a3 = List[String]()
    a3.append(String("-s"))
    a3.append(String("--max-time"))
    a3.append(String("5"))
    a3.append(String("http://example.com"))
    var r3 = sb.run(String("/usr/bin/curl"), a3)
    all_ok = _check(String("network egress (curl)"), False, r3) and all_ok

    _ = _sh("rm -rf demo")
    print()
    if all_ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("sandbox-demo: one or more containment checks failed")
