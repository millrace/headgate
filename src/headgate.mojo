"""headgate — entry point. Wires the layers and runs tasks over your data.

Layering (pi-shaped, PRIOR-ART.md):

    headgate.mojo        (this file — composition root + CLI/REPL)
        |
    orchestrator.mojo    core loop: synthetic-debug -> real-run
        |        \\
    transport.mojo       schema.mojo / egress.mojo   (confidentiality policy)
    (RemoteClient gated   - SchemaSanitizer, EgressGuard
     by EgressGuard;
     LocalClient local)
        |
    sandbox.mojo + broker.mojo   (containment — PROVEN, see SPIKE.md)

Usage:
    headgate "<task>"     run one task over your data and print the answer
    headgate              interactive REPL: type a task, get an answer, repeat

Data lives in `data_dir` (config: ~/.config/headgate/config.json, default
~/.config/headgate/data). On first run, if that folder has no .csv, headgate
asks where your data is — or seeds a small demo dataset.
"""

from std.sys import argv
from std.os import getenv, makedirs

from budget import Budget
from settings import load_config
from egress import EgressGuard
from schema import SchemaSanitizer, fingerprints_from_csv, csv_path_for
from transport import LocalClient, RemoteClient
from sandbox import Sandbox, SandboxPolicy
from broker import CapabilityBroker
from orchestrator import Orchestrator
from console import read_line


def _has_csv(data_dir: String) -> Bool:
    """True if `data_dir` exists and holds a .csv (no crash if it's missing)."""
    try:
        _ = csv_path_for(data_dir)
        return True
    except:
        return False


def _mkdirs(path: String):
    """`mkdir -p`; an already-existing path is fine (the error is swallowed)."""
    try:
        makedirs(path)
    except:
        pass  # already exists, or created concurrently


def _write_file(path: String, content: String) raises:
    with open(path, "w") as f:
        f.write(content)


def _seed_demo(data_dir: String) raises:
    """Create a tiny example CSV so a fresh install runs out of the box."""
    _mkdirs(data_dir)
    var csv = String(
        "name,category,amount\n"
        "alice,books,12\n"
        "bob,food,7\n"
        "carol,books,20\n"
        "dave,food,5\n"
        "erin,toys,9\n"
    )
    _write_file(data_dir + "/records.csv", csv)
    print("Created a demo dataset at " + data_dir + "/records.csv")


def _resolve_data_dir(var data_dir: String) raises -> String:
    """Return a data dir that holds a .csv. If the configured one doesn't (first
    run), ask the user where their data is — or seed a demo on an empty answer."""
    if _has_csv(data_dir):
        return data_dir^
    print("No data found at: " + data_dir)
    var r = read_line(
        "Path to a folder with your .csv (or press Enter to create a demo here): ")
    var chosen = r.text
    if chosen != "":
        if not _has_csv(chosen):
            raise Error("no .csv found in: " + chosen)
        print(
            "Using " + chosen + '.  (Set "data_dir" in '
            "~/.config/headgate/config.json to remember it.)")
        return chosen^
    _seed_demo(data_dir)
    return data_dir^


def main() raises:
    # Config: ~/.config/headgate/config.json (+ env overrides). See settings.mojo.
    var cfg = load_config()

    # Data dir from config (default ~/.config/headgate/data). Resolve BEFORE the
    # guard — it fingerprints the real CSV — asking on first run if there's none.
    var data_dir = _resolve_data_dir(cfg.data_dir.copy())
    var scratch_dir = getenv("HOME", "") + "/.config/headgate/scratch"
    _mkdirs(scratch_dir)

    # Confidentiality: build the guard from the real data — fingerprints of real
    # values (+ canaries seeded into the data). The guard is ON, not a no-op.
    var guard = EgressGuard(fingerprints_from_csv(data_dir), List[String]())

    # Two models: local (on-device, sees real data) and remote (frontier, gated).
    var local = LocalClient(cfg.local_url.copy(), cfg.local_model.copy())
    var remote = RemoteClient(
        cfg.remote_base_url.copy(), cfg.api_key.copy(), cfg.remote_model.copy(),
        cfg.mock, guard^,
    )

    # Containment: network-deny sandbox over the proven Seatbelt profile.
    var policy = SandboxPolicy(data_dir.copy(), scratch_dir.copy())
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

    # A task on the command line -> run it once. No task -> interactive REPL.
    var args = argv()
    if len(args) > 1:
        var task = String(args[1])
        for i in range(2, len(args)):
            task += " " + String(args[i])
        print(orch.run_task(task, data_dir.copy()))
        return

    print("headgate — ask a question about your data. Ctrl-D or 'exit' to quit.")
    while True:
        var r = read_line("\nheadgate> ")
        if r.eof:
            print("")
            break
        var task = r.text
        if task == "":
            continue
        if task == "exit" or task == "quit":
            break
        try:
            print(orch.run_task(task, data_dir.copy()))
        except:
            print(
                "error running the task — is the inference server running? "
                "(`millrace server start`, or set HEADGATE_MOCK=1 to try without it)")
