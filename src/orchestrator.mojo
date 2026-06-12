"""Orchestrator — headgate's core loop (pi's `pi-agent-core` equivalent).

VAULT-ONLY. Wires the layers into the privacy flow (README.md):

  1. `dacular manifest` produces the ALIASED view (the only vault info the remote
     model sees — never a real name, value, or path).
  2. RemoteClient.codegen writes a `from vault import *` program from that (every
     outbound message passes the EgressGuard — confidentiality enforced here).
  3. compile it (with the dacular include paths), looping the fix on COMPILE
     errors only; the code is in terms of aliases, so there is no dealias step.
  4. run the program in the loopback Sandbox over REAL data; only the printed
     answer surfaces. search()/ask_local() reach 127.0.0.1 only.

See run_vault_task for the full confidentiality argument.
"""

from std.os import setenv

from budget import Budget
from transport import LocalClient, RemoteClient, ChatMessage
from sandbox import Sandbox
from broker import CapabilityBroker
from vaultcfg import dacular_bin, vault_include_paths


struct Orchestrator(Movable):
    var local: LocalClient
    var remote: RemoteClient
    var sandbox: Sandbox
    var broker: CapabilityBroker
    var budget: Budget               # remote-API token budget; routes to local when depleted
    var use_local_summary: Bool      # have the local model summarize the result
    var max_fix_attempts: Int        # compile-feedback retries before giving up

    def __init__(
        out self,
        var local: LocalClient,
        var remote: RemoteClient,
        var sandbox: Sandbox,
        var broker: CapabilityBroker,
        var budget: Budget,
        use_local_summary: Bool,
    ):
        self.local = local^
        self.remote = remote^
        self.sandbox = sandbox^
        self.broker = broker^
        self.budget = budget^
        self.use_local_summary = use_local_summary
        self.max_fix_attempts = 3

    def _codegen(mut self, messages: List[ChatMessage]) raises -> String:
        """Route code generation: the remote frontier model while budget remains,
        else the LOCAL model (trusted + free). Charges the budget by the remote
        token cost."""
        if self.budget.depleted():
            return self.local.codegen(messages)
        var g = self.remote.codegen(messages)
        self.budget.charge(g.tokens)
        return g.code.copy()

    def _fix(mut self, code: String, errors: String) raises -> String:
        """Route a fix the same way — remote while budget remains, else local."""
        if self.budget.depleted():
            return self.local.fix_code(code, errors)
        var g = self.remote.fix_code(code, errors)
        self.budget.charge(g.tokens)
        return g.code.copy()

    def run_vault_task(mut self, question: String, vault_dir: String) raises -> String:
        """Answer a question about the private vault by writing ONE Mojo program
        that does `from vault import *` and calls the vault tools, compiling it
        with the dacular include paths, and running it in the loopback sandbox
        over the REAL data. Only the printed answer surfaces.

        This is the existing confidentiality model extended from "read one CSV" to
        "use the vault tools". The CONFIDENTIALITY INVARIANT, held end to end:

          - The ONLY vault information that reaches the remote (frontier) model is
            the ALIASED manifest (`file_0 [csv] 130 bytes  schema: col_0, col_1`)
            produced by `dacular manifest` — aliases/kinds/sizes/aliased columns,
            never a real name, value, or path (see dacular/src/manifest.mojo).
          - The question is the user's to send; the data is not. Every outbound
            message still passes the EgressGuard inside codegen()/fix_code()
            (fails closed) — a real value leaking into the manifest would trip it.
          - The generated program is written in terms of ALIASES (the tools TAKE
            aliases and resolve them locally), so there is NO dealias step — and
            nothing real is ever injected into the code (unlike the CSV path).
          - The program runs locally; search()/ask_local() hit ONLY 127.0.0.1
            (the loopback-only run profile, headgate-vault.sb.template, denies all
            other network); the answer is printed locally and returned here.

        So: aliases out, code back, run local over real data, answer local. The
        real content is touched only by the on-device tools, never the frontier."""
        # 1. The aliased manifest — the frontier-safe view. Shell out to the
        #    trusted `dacular manifest <vault_dir>` and capture its stdout. This
        #    is the ONLY vault info that will reach the remote model, and it is
        #    aliases-only by construction.
        var dac = dacular_bin()
        var manifest_argv: List[String] = [dac, String("manifest"), vault_dir]
        var m = self.sandbox.capture(manifest_argv)
        if m.exit_code != 0:
            raise Error(
                "vault: `dacular manifest` failed (is dacular built at " + dac
                + "? try `pixi run build` in dacular). Output:\n" + m.output)
        var manifest = m.output.copy()

        # 2. Codegen. The system prompt IS resources/headgate-system.md (loaded as
        #    the Anthropic system field / prepended locally by transport) — it
        #    documents the vault tools + the confidentiality contract. We do NOT
        #    add the CSV "read the CSV at __DATA_CSV__" system message here (it
        #    would conflict). We send ONLY the aliased manifest + the question as
        #    the user turn. Each outbound message clears the EgressGuard.
        var msgs = List[ChatMessage]()
        msgs.append(ChatMessage(String("user"),
            String("Question: ") + question
            + "\n\nVault manifest (aliases only — you never see real content):\n"
            + manifest
            + "\n\nWrite the Mojo program (`from vault import *`) that answers it."))
        var code = self._codegen(msgs)

        # 3. Compile with the vault include paths so `from vault import *` + its
        #    transitive deps resolve. On a compile error, feed the (aliased) error
        #    back to the model and retry — same fix loop as the CSV path. The code
        #    is already in terms of aliases, so there is no dealias step.
        #
        #    CONFIDENTIALITY NOTE — why this loops on COMPILE errors ONLY, never
        #    RUNTIME errors (the CSV path can loop on both, because its synthetic
        #    run uses fake data): a vault RUNTIME error can contain REAL content —
        #    e.g. an ask_local reply derived from a real chunk, or a real value in
        #    a stack trace. That content was seen only by the on-device model and
        #    must NOT be fed back to the remote (frontier) fixer. Compiler errors,
        #    by contrast, reference only the aliased SOURCE (col_0, file_0) and are
        #    safe. So we iterate compilation, but a runtime failure surfaces raw to
        #    the user (local) and is never sent upstream. (The EgressGuard would
        #    fail closed on a fingerprint, but with no per-file fingerprints on the
        #    vault path, not looping on runtime errors is the load-bearing control.)
        var includes = vault_include_paths()
        var compiled = self.sandbox.compile(code, includes)
        var attempt = 0
        while compiled.exit_code != 0 and attempt < self.max_fix_attempts:
            code = self._fix(code, compiled.output)   # budget-routed; guarded; aliased
            compiled = self.sandbox.compile(code, includes)
            attempt += 1
        if compiled.exit_code != 0:
            raise Error(
                "vault: generated program did not compile after "
                + String(self.max_fix_attempts) + " fix attempt(s). Last error:\n"
                + compiled.output)

        # 4. Run the compiled binary in the LOOPBACK sandbox (network-denied EXCEPT
        #    127.0.0.1, so search()/ask_local() reach the local models but the
        #    program still cannot phone home). DACULAR_VAULT points the tools at
        #    the real vault dir (inherited by the child via the process environ);
        #    the program reads it ONLY through the tools. The sandbox policy is in
        #    "loopback" mode (wired in build_vault_orchestrator), so run() renders
        #    the vault profile. Return stdout (the print_answer output) — local.
        _ = setenv("DACULAR_VAULT", vault_dir, True)
        var bin = self.sandbox.scratch_bin()
        return self.sandbox.run(bin, List[String]()).output.copy()
