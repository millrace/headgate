"""Orchestrator — headgate's core loop (pi's `pi-agent-core` equivalent).

Wires the layers into the privacy flow (README.md). v1 thin slice = a single
non-iterating pass:

  1. SchemaSanitizer derives an aliased schema + synthetic samples (no real data).
  2. RemoteClient.codegen writes code from that (every outbound message passes the
     EgressGuard — confidentiality enforced here).
  3. dealias the code (aliases -> real names) and inject the real CSV path, locally.
  4. compile + run the program in the Sandbox over REAL data; output stays local.

TODO (#5b): the synthetic-debug loop (iterate codegen<->run on synthetic data,
feeding scrubbed errors back) and LocalClient summarization of the result. v1
returns the raw computed result.
"""

from std.os import getenv
from budget import Budget
from schema import SchemaSanitizer, csv_path_for, inject_data_path
from transport import LocalClient, RemoteClient, ChatMessage
from sandbox import Sandbox
from broker import CapabilityBroker


struct Orchestrator(Movable):
    var local: LocalClient
    var remote: RemoteClient
    var sanitizer: SchemaSanitizer
    var sandbox: Sandbox
    var broker: CapabilityBroker
    var budget: Budget          # remote-API token budget; routes to local when depleted
    var max_fix_attempts: Int   # compile/runtime-feedback retries before giving up

    def __init__(
        out self,
        var local: LocalClient,
        var remote: RemoteClient,
        var sanitizer: SchemaSanitizer,
        var sandbox: Sandbox,
        var broker: CapabilityBroker,
        var budget: Budget,
    ):
        self.local = local^
        self.remote = remote^
        self.sanitizer = sanitizer^
        self.sandbox = sandbox^
        self.broker = broker^
        self.budget = budget^
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

    def run_task(mut self, intent: String, data_dir: String) raises -> String:
        """Execute one privacy-preserving task end to end (single pass)."""
        # 1. Sanitize: aliased schema + synthetic samples (no real data/names).
        var schema = self.sanitizer.sanitize(data_dir)

        # 2. Codegen — outbound messages carry only the aliased schema + fakes, and
        #    each is run through the EgressGuard inside codegen().
        var msgs = List[ChatMessage]()
        msgs.append(ChatMessage(String("system"),
            String("Write a Mojo program that reads the CSV at __DATA_CSV__ and"
                   " prints the result. Refer to columns by their aliases.")))
        msgs.append(ChatMessage(String("user"),
            intent + String("\nschema=") + schema.aliased_json()
                   + String("\nsamples=") + schema.synthetic_samples(3)))
        var code = self._codegen(msgs)

        # 3. Feedback loop on SYNTHETIC data: compile AND run the aliased code
        #    against a synthetic CSV (aliased headers col_0…, fake values), and on
        #    any failure send the error back to the model to fix. This catches BOTH
        #    compile and RUNTIME errors, and everything sent upstream carries only
        #    aliases + synthetic values — never real data. (The code reads the CSV at
        #    __DATA_CSV__; we inject the synthetic path here, the real one in step 4.)
        var syn_csv = self.sandbox.write_scratch(
            String("synthetic.csv"), schema.synthetic_csv(8))
        var attempt = 0
        while attempt < self.max_fix_attempts:
            var r = self.sandbox.compile_and_run(
                inject_data_path(code, syn_csv), List[String]())
            if r.exit_code == 0:
                break
            code = self._fix(code, r.output)   # budget-routed; guarded; aliased in/out
            attempt += 1

        # 4. Validated -> map aliases back to real names + inject the real CSV path
        #    LOCALLY, then compile + run over REAL data in the sandbox. Output local.
        var prog = inject_data_path(schema.dealias_code(code), csv_path_for(data_dir))
        var result = self.sandbox.compile_and_run(prog, List[String]())

        # 5. The LOCAL model (the TRUSTED party — it may see real data; talks only
        #    to 127.0.0.1) summarizes the computed result for the user. This is the
        #    inverse of the remote path: NO egress guard, because nothing leaves the
        #    machine. Opt-in via HEADGATE_LOCAL so offline runs (no inference-server)
        #    still work and just return the raw result.
        if getenv("HEADGATE_LOCAL", "") == "":
            return result.output.copy()
        var summary = List[ChatMessage]()
        summary.append(ChatMessage(String("system"),
            String("You are given a task and the raw result computed over the"
                   " user's private data. Summarize the result in one short"
                   " sentence for the user.")))
        summary.append(ChatMessage(String("user"),
            String("Task: ") + intent + "\nResult: " + result.output))
        return self.local.chat(summary)
