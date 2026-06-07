"""SchemaSanitizer — derive a sendable schema + synthetic samples from private data.

Confidentiality policy, sibling of the EgressGuard (both are outbound transforms
toward the remote model). The remote model must reason about the *shape* of the
data without seeing real values OR real names — column/table names can leak on
their own (`hiv_status`, `project_titanfall_revenue`).

So this layer produces two things the remote model is allowed to see:
  - an ALIASED schema: real names -> opaque ids (col_0, col_1, ...), with the
    reverse map kept ONLY locally (applied to generated code before it runs).
  - SYNTHETIC sample rows matching the aliased schema's types — fake values the
    remote model can use to write and debug code against.

The real data is never described by value or by name to the remote model.
"""


struct Column(Movable, Copyable):
    var real_name: String    # never leaves the machine
    var alias_name: String   # what the remote model sees, e.g. "col_3"
    var dtype: String        # "int" | "float" | "string" | "categorical[k]" | ...

    def __init__(out self, var real_name: String, var alias_name: String, var dtype: String):
        self.real_name = real_name^
        self.alias_name = alias_name^
        self.dtype = dtype^


struct SanitizedSchema(Movable):
    var columns: List[Column]

    def __init__(out self, var columns: List[Column]):
        self.columns = columns^

    def aliased_json(self) -> String:
        """The schema as the remote model sees it — aliases + dtypes only, no
        real names, no values. TODO: emit via minja2's JSON serializer."""
        return String("{}")  # TODO

    def synthetic_samples(self, n: Int) -> String:
        """`n` fake rows matching the aliased schema's types. Used for the
        debug loop so the remote never touches real data. TODO."""
        return String("[]")  # TODO

    def dealias_code(self, code: String) -> String:
        """Map aliases in generated code back to real names before the sandbox
        runs it locally. The reverse map stays here, never sent. TODO."""
        return code.copy()


struct SchemaSanitizer(Movable):
    def __init__(out self):
        pass

    def sanitize(self, data_dir: String) raises -> SanitizedSchema:
        """Inspect the private data at `data_dir`, derive types, alias names.
        Reads happen locally only. TODO: real introspection (CSV/parquet/SQL)."""
        return SanitizedSchema(List[Column]())  # TODO
