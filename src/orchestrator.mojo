"""Orchestrator — headgate's core loop (pi's `pi-agent-core` equivalent).

Wires the layers into the privacy flow from README.md. The key structural choice
that makes confidentiality cheap: a TWO-RUN design.

  1. SchemaSanitizer derives an aliased schema + synthetic samples (no real data).
  2. DEBUG LOOP, against SYNTHETIC data: ask the RemoteClient to write code; run
     it in the Sandbox over synthetic data; feed back scrubbed errors; iterate.
     Feedback can be generous here — there is no real data to leak.
  3. FINAL RUN, against REAL data: run the converged code once in the Sandbox.
     Its output stays LOCAL and never loops back to the remote model.
  4. The LocalClient (on-device model) summarizes the local result for the user.

The remote model is a code generator, never a live agent over the data — so there
is no tool-result feedback loop carrying real data upstream (per our design check).
"""

from schema import SchemaSanitizer, SanitizedSchema
from transport import LocalClient, RemoteClient, ChatMessage
from sandbox import Sandbox
from broker import CapabilityBroker


struct Orchestrator(Movable):
    var local: LocalClient
    var remote: RemoteClient
    var sanitizer: SchemaSanitizer
    var sandbox: Sandbox
    var broker: CapabilityBroker
    var max_debug_iters: Int

    def __init__(
        out self,
        var local: LocalClient,
        var remote: RemoteClient,
        var sanitizer: SchemaSanitizer,
        var sandbox: Sandbox,
        var broker: CapabilityBroker,
    ):
        self.local = local^
        self.remote = remote^
        self.sanitizer = sanitizer^
        self.sandbox = sandbox^
        self.broker = broker^
        self.max_debug_iters = 5

    def run_task(self, intent: String, data_dir: String) raises -> String:
        """Execute one privacy-preserving task end to end."""
        # 1. Sanitize: aliased schema + synthetic samples (no real data/names).
        var schema = self.sanitizer.sanitize(data_dir)

        # 2. Debug loop against SYNTHETIC data — remote writes code, sandbox runs
        #    it on fakes, scrubbed errors feed back. (RemoteClient.codegen runs
        #    every outbound message through the EgressGuard.)
        var code = self._debug_loop(intent, schema)

        # 3. Final run against REAL data; output stays local.
        var deal = schema.dealias_code(code)        # aliases -> real names, locally
        var real = self.sandbox.run(deal, List[String]())

        # 4. Local model summarizes the local result for the user.
        var msgs = List[ChatMessage]()
        msgs.append(ChatMessage(String("system"), String("Summarize the result.")))
        msgs.append(ChatMessage(String("user"), real.output.copy()))
        return self.local.chat(msgs)

    def _debug_loop(self, intent: String, schema: SanitizedSchema) raises -> String:
        """Iterate codegen <-> synthetic run until it passes or we give up."""
        var i = 0
        var code = String("")
        while i < self.max_debug_iters:
            var msgs = List[ChatMessage]()
            msgs.append(ChatMessage(String("system"),
                String("You write Mojo over a table; you NEVER see real data.")))
            msgs.append(ChatMessage(String("user"),
                intent + String("\nschema=") + schema.aliased_json()
                       + String("\nsamples=") + schema.synthetic_samples(3)))
            code = self.remote.codegen(msgs)              # guarded outbound
            var r = self.sandbox.run(code, List[String]())  # synthetic run
            if r.exit_code == 0:
                break
            i += 1
        return code
