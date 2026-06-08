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

v1 reads CSV. TODO: parquet / SQL; quoted-field + embedded-comma CSV handling.
"""

from std.os import listdir


# ── helpers ──────────────────────────────────────────────────────────────────

def _read_file(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _strip(s: String) -> String:
    return String(s.strip())


def _find_csv(data_dir: String) raises -> String:
    """First *.csv under data_dir. v1: matches the first name containing '.csv'."""
    var entries = listdir(data_dir)
    for e in entries:
        var name = String(e)
        if name.find(".csv") != -1:
            return data_dir + "/" + name
    raise Error("SchemaSanitizer: no .csv file found in " + data_dir)


def _is_int(s: String) -> Bool:
    var digits = 0
    var i = 0
    for cp in s.codepoints():
        var v = Int(cp)
        if i == 0 and v == 45:        # leading '-'
            i += 1
            continue
        if v < 48 or v > 57:          # not 0-9
            return False
        digits += 1
        i += 1
    return digits > 0


def _is_float(s: String) -> Bool:
    var digits = 0
    var dots = 0
    var i = 0
    for cp in s.codepoints():
        var v = Int(cp)
        if i == 0 and v == 45:
            i += 1
            continue
        if v == 46:                   # '.'
            dots += 1
            i += 1
            continue
        if v < 48 or v > 57:
            return False
        digits += 1
        i += 1
    return digits > 0 and dots <= 1


def _replace_all(s: String, old: String, new: String) raises -> String:
    var parts = s.split(old)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += new
        out += String(parts[i])
    return out


def csv_path_for(data_dir: String) raises -> String:
    """The CSV path the sanitizer used — so the orchestrator can point generated
    code at the real data file."""
    return _find_csv(data_dir)


def inject_data_path(code: String, csv_path: String) raises -> String:
    """Replace the data placeholder in generated code with the real CSV path,
    locally, just before compilation. Generated programs read `__DATA_CSV__`."""
    return _replace_all(code, String("__DATA_CSV__"), csv_path)


def fingerprints_from_csv(data_dir: String, min_len: Int = 4) raises -> List[String]:
    """Collect real-data spans (cell VALUES) to feed the EgressGuard. The header
    row is skipped on purpose: real column names are aliased away by the sanitizer
    (that's their protection), and fingerprinting common header words causes false
    positives — e.g. a header `name` collides with the JSON key "name" in the
    aliased schema. Values shorter than `min_len` are skipped to avoid over-blocking
    on ubiquitous short tokens — so this is defense-in-depth, not airtight (the
    careful-SaaS posture; canaries cover the high-signal case)."""
    var text = _read_file(_find_csv(data_dir))
    var lines = text.split("\n")
    var fps = List[String]()
    for li in range(1, len(lines)):   # skip header row
        var line = _strip(String(lines[li]))
        if line.byte_length() == 0:
            continue
        var fields = line.split(",")
        for fi in range(len(fields)):
            var v = _strip(String(fields[fi]))
            if v.byte_length() >= min_len:
                fps.append(v^)
    return fps^


# ── schema types ─────────────────────────────────────────────────────────────

struct Column(Movable, Copyable):
    var real_name: String    # never leaves the machine
    var alias_name: String   # what the remote model sees, e.g. "col_3"
    var dtype: String        # "int" | "float" | "string"

    def __init__(out self, var real_name: String, var alias_name: String, var dtype: String):
        self.real_name = real_name^
        self.alias_name = alias_name^
        self.dtype = dtype^


struct SanitizedSchema(Movable):
    var columns: List[Column]

    def __init__(out self, var columns: List[Column]):
        self.columns = columns^

    def aliased_json(self) -> String:
        """The schema as the remote model sees it — aliases + dtypes only."""
        var out = String("[")
        for i in range(len(self.columns)):
            if i > 0:
                out += ","
            out += '{"name":"' + self.columns[i].alias_name
            out += '","dtype":"' + self.columns[i].dtype + '"}'
        out += "]"
        return out

    def synthetic_samples(self, n: Int) -> String:
        """`n` fake rows matching the aliased schema's types — fakes only, so the
        remote model can write/debug code without touching real data."""
        var out = String("[")
        for r in range(n):
            if r > 0:
                out += ","
            out += "{"
            for c in range(len(self.columns)):
                if c > 0:
                    out += ","
                var dt = self.columns[c].dtype
                out += '"' + self.columns[c].alias_name + '":'
                if dt == "int":
                    out += String(r * 7 + 1)
                elif dt == "float":
                    out += String(r) + ".5"
                else:
                    out += '"s' + String(r) + '"'
            out += "}"
        out += "]"
        return out

    def dealias_code(self, code: String) raises -> String:
        """Map aliases in generated code back to real names before the sandbox
        runs it locally. The reverse map stays here, never sent.
        TODO: token-aware replace (naive substring can hit aliases inside words)."""
        var out = code.copy()
        for i in range(len(self.columns)):
            out = _replace_all(out, self.columns[i].alias_name, self.columns[i].real_name)
        return out


# ── the sanitizer ────────────────────────────────────────────────────────────

struct SchemaSanitizer(Movable):
    var sample_rows: Int   # how many data rows to scan for type inference

    def __init__(out self):
        self.sample_rows = 100

    def sanitize(self, data_dir: String) raises -> SanitizedSchema:
        """Inspect the CSV under data_dir, infer types, alias names. Local reads only."""
        var text = _read_file(_find_csv(data_dir))
        var lines = text.split("\n")
        if len(lines) == 0:
            raise Error("SchemaSanitizer: empty CSV")

        var names = String(lines[0]).split(",")
        var ncols = len(names)

        # Per-column type, widened from int -> float -> string as values demand.
        var dtypes = List[String]()
        for _c in range(ncols):
            dtypes.append(String("int"))

        var row = 1
        var scanned = 0
        while row < len(lines) and scanned < self.sample_rows:
            var line = _strip(String(lines[row]))
            row += 1
            if line.byte_length() == 0:
                continue
            scanned += 1
            var fields = line.split(",")
            for c in range(ncols):
                if c >= len(fields):
                    continue
                var val = _strip(String(fields[c]))
                if val.byte_length() == 0:
                    continue
                if dtypes[c] == "string":
                    continue
                if _is_int(val):
                    continue
                elif _is_float(val):
                    if dtypes[c] == "int":
                        dtypes[c] = String("float")
                else:
                    dtypes[c] = String("string")

        var cols = List[Column]()
        for c in range(ncols):
            var real = _strip(String(names[c]))
            var alias_id = String("col_") + String(c)
            cols.append(Column(real^, alias_id^, dtypes[c].copy()))
        return SanitizedSchema(cols^)
