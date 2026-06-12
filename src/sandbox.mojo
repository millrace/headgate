"""Sandbox — the CONTAINMENT half of headgate. Runs generated code in a box that
cannot phone home or escape its scope.

The boundary is PROVEN: see sandbox/headgate.sb.template + sandbox/spike.sh +
SPIKE.md (6/6 checks pass on macOS / Apple Silicon). This module renders that
template with canonical paths and runs a binary under `sandbox-exec`, FROM MOJO.

This is the first vertical slice filled in end-to-end: profile render
(file I/O + substitution) -> path canonicalization (realpath) -> exec under the
sandbox (system(3)) -> capture exit code + output. The loopback-only VAULT run
profile is verified by `pixi run vault-spike`.

Per pi's thesis (PRIOR-ART.md): isolation lives OUTSIDE the agent, at the OS
level. The harness owns confidentiality; this sandbox owns containment.

Implementation notes / honest TODOs:
- Exec uses `posix_spawn(2)` with an explicit argv vector and a
  `posix_spawn_file_actions_t` that redirects the child's stdout AND stderr to a
  file in scratch, which we then read back. No `/bin/sh`, no shell string, no
  quoting surface — argv entries are passed verbatim to `sandbox-exec`. This
  gives exit code + captured output. (Earlier this used `system(3)`; the shell
  was dropped to remove the quoting attack surface.)
- macOS only. Linux needs the Landlock+seccomp equivalent behind this same API.
"""

from std.ffi import external_call, c_int, c_char, CStringSlice
from std.memory import UnsafePointer, stack_allocation
from std.os import getenv


# ── posix_spawn-based exec ────────────────────────────────────────────────────
#
# macOS open(2) flags (sys/fcntl.h). Used by posix_spawn_file_actions_addopen to
# create/truncate the capture file and point the child's fd 1/2 at it.
comptime _O_WRONLY: c_int = 0x0001
comptime _O_CREAT: c_int = 0x0200
comptime _O_TRUNC: c_int = 0x0400
comptime _OUT_MODE: c_int = 0o644  # rw-r--r-- for the capture file

# A NULL `char*` / `void*` — argv terminator, attrp, etc.
comptime _NULL_CHARP = UnsafePointer[c_char, MutExternalOrigin](
    unsafe_from_address=Int(0)
)
comptime _NULL_VOIDP = UnsafePointer[NoneType, MutExternalOrigin](
    unsafe_from_address=Int(0)
)


def _cstr(s: String) -> UnsafePointer[c_char, MutExternalOrigin]:
    """malloc a NUL-terminated C copy of `s`. Caller owns it — `_free_cstr`."""
    var n = s.byte_length()
    var p = alloc[c_char](n + 1)
    var sp = s.unsafe_ptr()  # UnsafePointer[UInt8]
    for i in range(n):
        (p + i).init_pointee_copy(c_char(Int(sp[i])))
    (p + n).init_pointee_copy(c_char(0))
    return p


def _environ() -> UnsafePointer[
    UnsafePointer[c_char, MutExternalOrigin], MutExternalOrigin
]:
    """The process `environ` (`char**`). On macOS the global isn't directly
    linkable, so go through `_NSGetEnviron()` which returns `char***`; deref
    once. Passing this (NOT NULL) is MANDATORY: compile() relies on the child
    inheriting PATH / CONDA_PREFIX to find its toolchain + dylibs."""
    var pp = external_call[
        "_NSGetEnviron",
        UnsafePointer[
            UnsafePointer[
                UnsafePointer[c_char, MutExternalOrigin], MutExternalOrigin
            ],
            MutExternalOrigin,
        ],
    ]()
    return pp[]


def _spawn_capture(argv: List[String], out_path: String) raises -> Int:
    """Exec `argv` via posix_spawn with stdout+stderr redirected to `out_path`,
    wait for it, and return the child's exit code (WEXITSTATUS).

    `argv[0]` must be an absolute path (we use plain posix_spawn, not the
    PATH-searching posix_spawnp). stdout AND stderr land in `out_path`
    (O_WRONLY|O_CREAT|O_TRUNC, 0644) via posix_spawn_file_actions — this
    replaces the shell's `> file 2>&1`. The real process environ is inherited.

    Raises if argv is empty or any libc step (file_actions / spawn) fails. All
    C resources (the argv string array + each string, the file_actions) are
    freed before returning."""
    var n = len(argv)
    if n == 0:
        raise Error("_spawn_capture: empty argv")

    # Build NULL-terminated char** argv. Each entry is an owned C string.
    var cargv = alloc[UnsafePointer[c_char, MutExternalOrigin]](n + 1)
    for i in range(n):
        (cargv + i).init_pointee_copy(_cstr(argv[i]))
    (cargv + n).init_pointee_copy(_NULL_CHARP)

    # file_actions: macOS posix_spawn_file_actions_t is a single opaque pointer
    # (8 bytes); over-allocate to 64 bytes for forward safety. Open the capture
    # file as fd 1 (stdout), then dup2 fd 1 -> fd 2 so stderr shares it.
    var fa = stack_allocation[64, UInt8]()
    for i in range(64):
        fa[i] = 0
    var path_c = _cstr(out_path)

    var rc = external_call["posix_spawn_file_actions_init", c_int](
        fa.bitcast[NoneType]()
    )
    if rc == 0:
        rc = external_call["posix_spawn_file_actions_addopen", c_int](
            fa.bitcast[NoneType](),
            c_int(1),
            path_c,
            _O_WRONLY | _O_CREAT | _O_TRUNC,
            _OUT_MODE,
        )
    if rc == 0:
        rc = external_call["posix_spawn_file_actions_adddup2", c_int](
            fa.bitcast[NoneType](), c_int(1), c_int(2)
        )

    var exit_code = -1
    if rc == 0:
        var pid_slot = stack_allocation[1, c_int]()
        pid_slot[0] = 0
        # argv[0] is absolute -> plain posix_spawn (no PATH search). envp is the
        # inherited process environ (compile() needs PATH/CONDA_PREFIX).
        var src = external_call["posix_spawn", c_int](
            pid_slot.bitcast[NoneType](),
            cargv[0],  # path == argv[0] (absolute)
            fa.bitcast[NoneType](),
            _NULL_VOIDP,  # attrp
            cargv,
            _environ(),
        )
        if src == 0:
            var status_slot = stack_allocation[1, c_int]()
            status_slot[0] = 0
            _ = external_call["waitpid", c_int](
                pid_slot[0], status_slot.bitcast[NoneType](), c_int(0)
            )
            exit_code = (Int(status_slot[0]) >> 8) & 0xFF
        else:
            rc = src

    # Tear down C resources unconditionally.
    _ = external_call["posix_spawn_file_actions_destroy", c_int](
        fa.bitcast[NoneType]()
    )
    path_c.free()
    for i in range(n):
        cargv[i].free()
    cargv.free()

    if rc != 0:
        raise Error("posix_spawn failed (rc=" + String(rc) + ")")
    return exit_code


def _canonical(var path: String) raises -> String:
    """realpath(3): resolve symlinks + relative segments to an absolute path.
    MANDATORY — Seatbelt matches the real path, and /tmp -> /private/tmp on
    macOS (SPIKE.md). The path must exist."""
    var buf = stack_allocation[4096, UInt8]()
    buf[0] = 0
    _ = external_call["realpath", UnsafePointer[c_char, MutExternalOrigin]](
        path.as_c_string_slice(), buf.bitcast[c_char]()
    )
    if Int(buf[0]) == 0:
        raise Error("realpath failed (does it exist?): " + path)
    return String(
        StringSlice(unsafe_from_utf8=CStringSlice(unsafe_from_ptr=buf.bitcast[Int8]()))
    )


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _write(path: String, s: String) raises:
    with open(path, "w") as f:
        f.write(s)


def _replace_all(s: String, old: String, new: String) raises -> String:
    """Substitute every occurrence of `old` with `new`. (String has no slice
    syntax in current Mojo — split on `old` and rejoin with `new`.)"""
    var parts = s.split(old)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += new
        out += String(parts[i])
    return out


def _strip_compiler_noise(s: String) raises -> String:
    """Drop Mojo's crashpad-init warnings — the compiler's crash reporter can't
    grab a mach port under the compile sandbox, so it prints a few lines and
    continues. Keeps the real compiler errors clean for the feedback loop."""
    var lines = s.split("\n")
    var out = String("")
    var first = True
    for i in range(len(lines)):
        var ln = String(lines[i])
        if (
            ln.find("crashpad") != -1
            or ln.find("Crashpad") != -1
            or ln.find("child_port_handshake") != -1
            or ln.find("ReadExactly") != -1
            or ln.find("Crash reporting") != -1
        ):
            continue
        if not first:
            out += "\n"
        out += ln
        first = False
    return out


# ── policy + result ──────────────────────────────────────────────────────────

struct SandboxPolicy(Movable):
    var data_dir: String      # read-only mount of the task's private data
    var scratch_dir: String   # the only writable location (results land here)
    var network: String       # "deny" (CSV path) | "loopback" (vault path)
    var index_dir: String     # the vault's LanceDB index dir (~/.config/dacular);
                              # read-allowed in the vault run profile so search()
                              # can read the vector store + chunks.tsv side-table

    def __init__(out self, var data_dir: String, var scratch_dir: String):
        self.data_dir = data_dir^
        self.scratch_dir = scratch_dir^
        self.network = String("deny")
        self.index_dir = String("")

    def __init__(out self, var data_dir: String, var scratch_dir: String,
                 var index_dir: String, var network: String):
        """Vault variant: carries the index dir + the network mode ("loopback")."""
        self.data_dir = data_dir^
        self.scratch_dir = scratch_dir^
        self.network = network^
        self.index_dir = index_dir^


struct RunResult(Movable):
    var exit_code: Int
    var output: String   # combined stdout+stderr; passes the EgressGuard before reuse

    def __init__(out self, exit_code: Int, var output: String):
        self.exit_code = exit_code
        self.output = output^


# ── the runner ───────────────────────────────────────────────────────────────

struct Sandbox(Movable):
    var policy: SandboxPolicy
    var template_path: String   # sandbox/headgate.sb.template

    def __init__(out self, var policy: SandboxPolicy, var template_path: String):
        self.policy = policy^
        self.template_path = template_path^

    def _render_profile(self, scratch_c: String) raises -> String:
        """Substitute @DATA_DIR@ / @SCRATCH_DIR@ / @HOME@ with canonical paths,
        write the rendered profile into scratch, return its path. When the policy
        is in "loopback" mode (the vault path), renders the VAULT template
        (headgate-vault.sb.template) instead — same containment, plus a localhost-
        only network allowance + the index dir read-allow."""
        var is_vault = self.policy.network == "loopback"
        var tmpl_path = (
            _replace_all(
                self.template_path,
                String("headgate.sb.template"),
                String("headgate-vault.sb.template"),
            )
            if is_vault else self.template_path
        )
        var tmpl = _read(tmpl_path)
        var data_c = _canonical(self.policy.data_dir)
        var home_c = _canonical(getenv("HOME", "/"))
        # The Mojo runtime/toolchain (pixi env) lives under $HOME; allow reading it
        # so compiled binaries can load their dylibs. CONDA_PREFIX points at the env.
        var runtime = getenv("CONDA_PREFIX", "/nonexistent-runtime")
        var rendered = _replace_all(tmpl, String("@DATA_DIR@"), data_c)
        rendered = _replace_all(rendered, String("@SCRATCH_DIR@"), scratch_c)
        rendered = _replace_all(rendered, String("@HOME@"), home_c)
        rendered = _replace_all(rendered, String("@RUNTIME_PREFIX@"), runtime)
        if is_vault:
            # The index dir (~/.config/dacular) lives under $HOME; canonicalize it
            # so the vault profile can re-allow reads of the vector store + the
            # chunks.tsv side-table that search() resolves hits through.
            var index_c = _canonical(
                self.policy.index_dir if self.policy.index_dir != ""
                else (getenv("HOME", "/") + "/.config/dacular"))
            rendered = _replace_all(rendered, String("@INDEX_DIR@"), index_c)
        var path = scratch_c + ("/headgate-vault.sb" if is_vault else "/headgate.sb")
        _write(path, rendered)
        return path

    def run(self, binary: String, args: List[String]) raises -> RunResult:
        """Run `binary args...` under sandbox-exec with the rendered headgate
        profile: network denied (or loopback-only on the vault path), writes
        confined to scratch, reads exclude $HOME.

            sandbox-exec -f <rendered.sb> <binary> <args...>

        Exec'd via posix_spawn (no shell); stdout+stderr captured to <out>.
        """
        var scratch_c = _canonical(self.policy.scratch_dir)
        var profile = self._render_profile(scratch_c)
        var outfile = scratch_c + "/run.out"

        var argv: List[String] = [
            String("/usr/bin/sandbox-exec"),
            String("-f"),
            profile,
            binary,
        ]
        for i in range(len(args)):
            argv.append(args[i])

        var code = _spawn_capture(argv, outfile)
        var out: String
        try:
            out = _read(outfile)
        except:
            out = String("")
        return RunResult(code, out^)

    def write_scratch(self, name: String, content: String) raises -> String:
        """Write `content` to `name` in the scratch dir; return its canonical path.
        Stages synthetic data for the runtime-feedback loop (scratch is readable in
        the sandbox profile)."""
        var scratch_c = _canonical(self.policy.scratch_dir)
        var path = scratch_c + "/" + name
        _write(path, content)
        return path

    def scratch_bin(self) raises -> String:
        """Canonical path of the binary `compile` writes (scratch/gen). The vault
        path compiles then runs in two steps, so it needs this between them."""
        return _canonical(self.policy.scratch_dir) + "/gen"

    def capture(self, argv: List[String]) raises -> RunResult:
        """Run a TRUSTED local helper `argv` (NOT sandboxed) and capture its
        stdout+stderr. Used by the vault path to invoke `dacular manifest <dir>`,
        which produces the aliased, frontier-SAFE manifest view. argv[0] must be
        an absolute path. This is trusted: it computes the alias mapping locally
        and never sends anything anywhere — the *output* is what becomes
        frontier-visible, and it is aliases-only by construction (manifest.mojo)."""
        var scratch_c = _canonical(self.policy.scratch_dir)
        var outfile = scratch_c + "/capture.out"
        var code = _spawn_capture(argv, outfile)
        var out: String
        try:
            out = _read(outfile)
        except:
            out = String("")
        return RunResult(code, out^)

    def _render_compile_profile(self, scratch_c: String, prefix: String) raises -> String:
        """Render compile.sb.template (sibling of the run template) with canonical
        paths; write to scratch; return its path."""
        var tmpl_path = _replace_all(
            self.template_path, String("headgate.sb.template"), String("compile.sb.template"))
        var tmpl = _read(tmpl_path)
        var home_c = _canonical(getenv("HOME", "/"))
        var tmp_c = _canonical(getenv("TMPDIR", "/tmp"))
        var runtime = prefix if prefix != "" else String("/nonexistent-runtime")
        var r = _replace_all(tmpl, String("@SCRATCH_DIR@"), scratch_c)
        r = _replace_all(r, String("@HOME@"), home_c)
        r = _replace_all(r, String("@TMPDIR@"), tmp_c)
        r = _replace_all(r, String("@RUNTIME_PREFIX@"), runtime)
        var path = scratch_c + "/compile.sb"
        _write(path, r)
        return path

    def compile(self, source: String, include_paths: List[String] = List[String]()) raises -> RunResult:
        """Compile generated Mojo `source` to a binary in scratch (NO run).
        Returns RunResult(0, "") on success, or (rc, compiler errors) on failure.
        Used to VALIDATE code before dealiasing — so compiler errors fed back to the
        remote model carry only aliased names (col_0…), never real data.

        `include_paths` are `mojo build`'s `-I` search dirs. For the VAULT path
        these are the dacular `src` dir + its transitive deps (flare/json/lancedb/
        pdftotext/zlib) so the generated `from vault import *` + everything it
        pulls resolves. Empty for the CSV path (no imports beyond stdlib).

        The compile runs UNDER a network-denied sandbox (sandbox/compile.sb.template):
        Mojo `comptime` executes at build time, so this contains it — no network
        (can't phone home), writes scoped to scratch/toolchain/temp. Reads stay
        broad (`allow file-read* file-map-executable` — the compiler needs its
        toolchain AND the -I sibling source dirs + the FFI shims under
        $CONDA_PREFIX/lib, all reachable under that broad read allow). The *run*
        step is separately contained + read-scoped (headgate{,-vault}.sb.template)."""
        var scratch_c = _canonical(self.policy.scratch_dir)
        var src_path = scratch_c + "/gen.mojo"
        var bin_path = scratch_c + "/gen"
        var build_out = scratch_c + "/build.out"
        _write(src_path, source)

        # Absolute mojo path: the harness may be launched without pixi's PATH
        # activation (e.g. ./build/headgate), so don't rely on `mojo` being on PATH.
        var prefix = getenv("CONDA_PREFIX", "")
        var mojo_bin = (prefix + "/bin/mojo") if prefix != "" else String("mojo")
        var profile = self._render_compile_profile(scratch_c, prefix)

        # sandbox-exec -f <profile> <mojo> build <src> -I <p1> -I <p2> … -o <bin>
        # No shell: argv passed verbatim, stdout+stderr captured to build_out.
        var build_argv: List[String] = [
            String("/usr/bin/sandbox-exec"),
            String("-f"),
            profile,
            mojo_bin,
            String("build"),
            src_path,
        ]
        for i in range(len(include_paths)):
            build_argv.append(String("-I"))
            build_argv.append(include_paths[i])
        build_argv.append(String("-o"))
        build_argv.append(bin_path)

        var brc = _spawn_capture(build_argv, build_out)
        if brc != 0:
            var berr: String
            try:
                berr = _read(build_out)
            except:
                berr = String("")
            return RunResult(brc, _strip_compiler_noise(berr^))
        return RunResult(0, String(""))

    def compile_and_run(
        self,
        source: String,
        args: List[String],
        include_paths: List[String] = List[String](),
    ) raises -> RunResult:
        """Compile `source` (with `-I include_paths`), then run the binary under
        the sandbox. The run step is fully contained (the compile is not — see
        `compile`). On the vault path the policy is in "loopback" network mode, so
        run() picks the vault profile automatically."""
        var c = self.compile(source, include_paths)
        if c.exit_code != 0:
            return RunResult(c.exit_code, String("compile failed:\n") + c.output)
        var scratch_c = _canonical(self.policy.scratch_dir)
        return self.run(scratch_c + "/gen", args)
