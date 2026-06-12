"""headgate — CLI entry point. The private-VAULT harness: a frontier model writes
a Mojo program that uses the dacular vault tools; it runs locally over the real
data and only the printed answer surfaces.

Layering (pi-shaped, PRIOR-ART.md):

    headgate.mojo        (this file — CLI)          server.mojo (HTTP, web)
              \\                                      /
               wiring.mojo   build_vault_orchestrator(cfg, vault_dir)
                                  |
    orchestrator.mojo    core loop: codegen -> compile-fix -> run (loopback)
        |        \\
    transport.mojo       egress.mojo   (confidentiality policy)
        |
    sandbox.mojo + broker.mojo   (containment — PROVEN, see SPIKE.md)

Usage:
    headgate vault "<question>" [dir]  answer a question about your private VAULT
                                       (CSV/PDF/Markdown). The frontier model writes
                                       a Mojo program that uses the dacular vault
                                       tools; it runs locally over the real data and
                                       only the printed answer surfaces.

The vault dir defaults to $DACULAR_VAULT, else $HEADGATE_DATA, else ~/dacular.
Index it first with `dacular index <dir>` (needs the embedding server live).
"""

from std.sys import argv
from std.os import getenv

from settings import load_config
from wiring import build_vault_orchestrator


def _vault_dir(var arg: String) raises -> String:
    """Resolve the vault dir for the `vault` subcommand: an explicit CLI arg wins,
    then $DACULAR_VAULT, then $HEADGATE_DATA, then ~/dacular (dacular's own
    default). Kept consistent with dacular/src/vault.mojo `_vault_dir()`."""
    if arg != "":
        return arg^
    var d = getenv("DACULAR_VAULT", "")
    if d != "":
        return d
    d = getenv("HEADGATE_DATA", "")
    if d != "":
        return d
    return getenv("HOME", ".") + "/dacular"


def _run_vault(question: String, var vault_dir: String) raises:
    """`headgate vault "<question>" [dir]` — the vault codegen loop."""
    var cfg = load_config()
    var dir = _vault_dir(vault_dir^)
    var orch = build_vault_orchestrator(cfg, dir)
    print(orch.run_vault_task(question, dir.copy()))


def main() raises:
    # `headgate vault "<question>" [dir]` — the private-vault codegen loop. This is
    # THE query path: headgate is the vault harness, not a CSV tool.
    var argv0 = argv()
    if len(argv0) > 1 and String(argv0[1]) == "vault":
        if len(argv0) < 3:
            print('usage: headgate vault "<question>" [vault_dir]')
            return
        var question = String(argv0[2])
        var vdir = String(argv0[3]) if len(argv0) >= 4 else String("")
        _run_vault(question, vdir^)
        return

    print('usage: headgate vault "<question>" [vault_dir]')
    print("  Answer a question about your private VAULT (CSV/PDF/Markdown).")
    print("  Index it first with `dacular index <dir>` (embedding server live).")
    print("  The vault dir defaults to $DACULAR_VAULT, else $HEADGATE_DATA, else ~/dacular.")
