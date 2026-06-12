"""wiring — build the headgate VAULT orchestrator.

Shared by the CLI (headgate.mojo) and the HTTP server (server.mojo) so both go
through one composition path. Kept out of headgate.mojo (which owns `main`) so
server.mojo can import it without pulling in a second `main`.
"""

from std.os import getenv, makedirs

from budget import Budget
from settings import Config
from egress import EgressGuard
from transport import LocalClient, RemoteClient
from sandbox import Sandbox, SandboxPolicy
from broker import CapabilityBroker
from orchestrator import Orchestrator
from vaultcfg import vault_index_dir


def mkdirs(path: String):
    """`mkdir -p`; an already-existing path is fine (the error is swallowed)."""
    try:
        makedirs(path)
    except:
        pass  # already exists, or created concurrently


def scratch_dir() -> String:
    """The sandbox scratch dir (always writable, created on use)."""
    return getenv("HOME", "") + "/.config/headgate/scratch"


def build_vault_orchestrator(cfg: Config, vault_dir: String) raises -> Orchestrator:
    """Wire the orchestrator for the VAULT path (run_vault_task):

      - the sandbox policy is in "loopback" network mode with the vault dir as the
        (read-only) data dir + the LanceDB index dir read-allowed, so the run
        profile renders headgate-vault.sb.template (loopback-only egress);
      - the EgressGuard is fingerprinted from NO real content — the vault path
        never reads real values into the guard; it sends only the ALIASED
        manifest. The guard still blocks canary tokens and any configured secret,
        and the manifest is aliases-only by construction (dacular/manifest.mojo),
        so confidentiality holds without per-file fingerprints. (search/ask_local
        results never go upstream — they print locally.)"""
    var scratch = scratch_dir()
    mkdirs(scratch)

    var guard = EgressGuard(List[String](), List[String]())
    var local = LocalClient(cfg.local_url.copy(), cfg.local_model.copy())
    var remote = RemoteClient(
        cfg.remote_base_url.copy(), cfg.api_key.copy(), cfg.remote_model.copy(),
        cfg.mock, guard^,
    )
    var policy = SandboxPolicy(
        vault_dir.copy(), scratch.copy(), vault_index_dir(), String("loopback"))
    var sandbox = Sandbox(policy^, String("sandbox/headgate.sb.template"))

    var allowed = List[String]()
    allowed.append(String("vault_tools"))
    allowed.append(String("ask_local"))
    var broker = CapabilityBroker(allowed^)

    var budget = Budget(cfg.remote_token_budget)
    return Orchestrator(
        local^, remote^, sandbox^, broker^, budget^,
        cfg.use_local_summary)
