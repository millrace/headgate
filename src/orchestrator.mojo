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

    def run_task(self, intent: String, data_dir: String) raises -> String:
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
        var code = self.remote.codegen(msgs)

        # 3. Map aliases back to real names, inject the real CSV path — LOCALLY.
        var deal = schema.dealias_code(code)
        var prog = inject_data_path(deal, csv_path_for(data_dir))

        # 4. Compile + run in the sandbox over REAL data; result stays local.
        var result = self.sandbox.compile_and_run(prog, List[String]())
        return result.output.copy()
