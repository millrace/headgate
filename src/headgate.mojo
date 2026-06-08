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

from budget import Budget
from settings import load_config
from egress import EgressGuard
from schema import SchemaSanitizer, fingerprints_from_csv
from transport import LocalClient, RemoteClient
from sandbox import Sandbox, SandboxPolicy
from broker import CapabilityBroker
from orchestrator import Orchestrator


def main() raises:
    # Config: ~/.config/headgate/config.json (+ env overrides). See settings.mojo.
    var cfg = load_config()
    var data_dir = String("./demo/data")

    # Confidentiality: build the guard from the real data — fingerprints of real
    # values (+ canaries seeded into the data). The guard is now ON, not a no-op.
    var guard = EgressGuard(fingerprints_from_csv(data_dir), List[String]())

    # Two models: local (on-device, sees real data) and remote (frontier, gated).
    var local = LocalClient(cfg.local_url.copy(), cfg.local_model.copy())
    var remote = RemoteClient(
        cfg.remote_base_url.copy(), cfg.api_key.copy(), cfg.remote_model.copy(),
        cfg.mock, guard^,
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

    # Remote-API token budget: when depleted, codegen + fixes route to the local model.
    var budget = Budget(cfg.remote_token_budget)

    var orch = Orchestrator(
        local^, remote^, SchemaSanitizer(), sandbox^, broker^, budget^,
        cfg.use_local_summary)

    var answer = orch.run_task(
        String("Count rows grouped by category."),
        data_dir.copy(),
    )
    print(answer)
