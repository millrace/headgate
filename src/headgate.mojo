"""headgate — entry point. Wires the layers and runs one demo task.

Layering (pi-shaped, PRIOR-ART.md):

    headgate.mojo        (this file — composition root)
        |
    orchestrator.mojo    core loop: synthetic-debug -> real-run
        |        \\
    transport.mojo       schema.mojo / egress.mojo   (confidentiality policy)
    (RemoteClient gated   - SchemaSanitizer, EgressGuard
     by EgressGuard;
     LocalClient local)
        |
    sandbox.mojo + broker.mojo   (containment — PROVEN, see SPIKE.md)

`pixi run sandbox-demo` proves the containment boundary today. The rest of the
graph compiles (`pixi run build-full`) but the layers above the sandbox are still
stubs — the TODOs (flare transport, schema introspection, capability shim) are
where the real behavior goes next.
"""

from std.os import getenv
from budget import Budget, parse_budget
from egress import EgressGuard
from schema import SchemaSanitizer, fingerprints_from_csv
from transport import LocalClient, RemoteClient
from sandbox import Sandbox, SandboxPolicy
from broker import CapabilityBroker
from orchestrator import Orchestrator


def main() raises:
    var data_dir = String("./demo/data")

    # Confidentiality: build the guard from the real data — fingerprints of real
    # values (+ canaries seeded into the data). The guard is now ON, not a no-op.
    var guard = EgressGuard(fingerprints_from_csv(data_dir), List[String]())

    # Two models: local (on-device, sees real data) and remote (frontier, gated).
    var local = LocalClient(getenv("HEADGATE_LOCAL_URL", "http://127.0.0.1:8000/v1"))
    var remote = RemoteClient(
        String("https://api.anthropic.com/v1"),  # remote frontier model
        String(""),                              # API key from env (TODO)
        guard^,
    )

    # Containment: network-deny sandbox over the proven Seatbelt profile.
    var policy = SandboxPolicy(data_dir.copy(), String("./demo/scratch"))
    var sandbox = Sandbox(policy^, String("sandbox/headgate.sb.template"))

    # Capability allowlist for the generated code.
    var allowed = List[String]()
    allowed.append(String("read_table"))
    allowed.append(String("write_result"))
    allowed.append(String("log"))
    var broker = CapabilityBroker(allowed^)

    # Remote-API token budget: when depleted, codegen + fixes route to the local
    # model. HEADGATE_REMOTE_TOKEN_BUDGET: unset/-1 = unlimited, 0 = always-local,
    # N>0 = N tokens then local.
    var budget = Budget(parse_budget(getenv("HEADGATE_REMOTE_TOKEN_BUDGET", "-1")))

    var orch = Orchestrator(local^, remote^, SchemaSanitizer(), sandbox^, broker^, budget^)

    var answer = orch.run_task(
        String("Count rows grouped by category."),
        data_dir.copy(),
    )
    print(answer)
