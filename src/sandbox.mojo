"""Sandbox — the CONTAINMENT half of headgate. Runs generated code in a box that
cannot phone home or escape its scope.

The boundary is PROVEN: see sandbox/headgate.sb.template + sandbox/spike.sh +
SPIKE.md (6/6 checks pass on macOS / Apple Silicon). This module renders that
template with canonical paths and runs a binary under `sandbox-exec`, FROM MOJO.

This is the first vertical slice filled in end-to-end: profile render
(file I/O + substitution) -> path canonicalization (realpath) -> exec under the
sandbox (system(3)) -> capture exit code + output. It compiles and runs today
(`pixi run sandbox-demo`).

Per pi's thesis (PRIOR-ART.md): isolation lives OUTSIDE the agent, at the OS
level. The harness owns confidentiality; this sandbox owns containment.

Implementation notes / honest TODOs:
- Exec uses `system(3)` (i.e. `/bin/sh -c`) with the sandboxed command's output
  redirected to a file in scratch, which we then read back. This gives exit code
  + captured output with zero extra FFI. Hardening follow-up: `posix_spawn` with
  an explicit argv + a pipe, to drop the shell and avoid any quoting surface.
- macOS only. Linux needs the Landlock+seccomp equivalent behind this same API.
"""

from std.ffi import external_call, c_int, c_char, CStringSlice
from std.memory import UnsafePointer, stack_allocation
from std.os import getenv


# ── small libc helpers ───────────────────────────────────────────────────────

def _shell(var cmd: String) -> Int:
    """Run `cmd` via system(3); return the child's exit code (WEXITSTATUS)."""
    var status = Int(external_call["system", c_int](cmd.as_c_string_slice()))
    return (status >> 8) & 0xFF


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


# ── policy + result ──────────────────────────────────────────────────────────

struct SandboxPolicy(Movable):
    var data_dir: String      # read-only mount of the task's private data
    var scratch_dir: String   # the only writable location (results land here)
    var network: String       # always "deny" for v1 — the primary control

    def __init__(out self, var data_dir: String, var scratch_dir: String):
        self.data_dir = data_dir^
        self.scratch_dir = scratch_dir^
        self.network = String("deny")


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
        write the rendered profile into scratch, return its path."""
        var tmpl = _read(self.template_path)
        var data_c = _canonical(self.policy.data_dir)
        var home_c = _canonical(getenv("HOME", "/"))
        # The Mojo runtime/toolchain (pixi env) lives under $HOME; allow reading it
        # so compiled binaries can load their dylibs. CONDA_PREFIX points at the env.
        var runtime = getenv("CONDA_PREFIX", "/nonexistent-runtime")
        var rendered = _replace_all(tmpl, String("@DATA_DIR@"), data_c)
        rendered = _replace_all(rendered, String("@SCRATCH_DIR@"), scratch_c)
        rendered = _replace_all(rendered, String("@HOME@"), home_c)
        rendered = _replace_all(rendered, String("@RUNTIME_PREFIX@"), runtime)
        var path = scratch_c + "/headgate.sb"
        _write(path, rendered)
        return path

    def run(self, binary: String, args: List[String]) raises -> RunResult:
        """Run `binary args...` under sandbox-exec with the rendered headgate
        profile: network denied, writes confined to scratch, reads exclude $HOME.

            sandbox-exec -f <rendered.sb> <binary> <args...>  > <out> 2>&1
        """
        var scratch_c = _canonical(self.policy.scratch_dir)
        var profile = self._render_profile(scratch_c)
        var outfile = scratch_c + "/run.out"

        var cmd = String("sandbox-exec -f '") + profile + "' '" + binary + "'"
        for i in range(len(args)):
            cmd += String(" '") + args[i] + "'"
        cmd += String(" > '") + outfile + "' 2>&1"

        var code = _shell(cmd)
        var out: String
        try:
            out = _read(outfile)
        except:
            out = String("")
        return RunResult(code, out^)

    def compile_and_run(self, source: String, args: List[String]) raises -> RunResult:
        """Write generated Mojo `source` to scratch, compile it, then run the
        binary under the sandbox via `run()`. Returns the compile error as the
        RunResult on a build failure.

        v1 compiles OUTSIDE the sandbox. CAVEAT: Mojo `comptime` executes at BUILD
        time, so a hostile program could act during compilation, outside
        containment. Acceptable under the careful-SaaS threat model (model code is
        not adversarial); the adversarial tier must sandbox the compile too
        (network-denied) — TODO. The *run* step is fully contained either way."""
        var scratch_c = _canonical(self.policy.scratch_dir)
        var src_path = scratch_c + "/gen.mojo"
        var bin_path = scratch_c + "/gen"
        var build_out = scratch_c + "/build.out"
        _write(src_path, source)

        # Absolute mojo path: the harness may be launched without pixi's PATH
        # activation (e.g. ./build/headgate), so don't rely on `mojo` being on PATH.
        var prefix = getenv("CONDA_PREFIX", "")
        var mojo_bin = (prefix + "/bin/mojo") if prefix != "" else String("mojo")
        var build_cmd = String("'") + mojo_bin + "' build '" + src_path + "' -o '" + bin_path
        build_cmd += String("' > '") + build_out + "' 2>&1"
        var brc = _shell(build_cmd)
        if brc != 0:
            var berr: String
            try:
                berr = _read(build_out)
            except:
                berr = String("")
            return RunResult(brc, String("compile failed:\n") + berr^)

        return self.run(bin_path, args)
