# headgate

**A privacy harness: use a frontier model to write code that runs on private
data locally — the data never leaves the machine.**

A *headgate* is the gate at the intake of a millrace that controls how much water
enters the channel. This project is the controlled intake on the channel that
drives the mill: it lets a powerful remote model do the thinking, while keeping
your private data on your side of the gate.

## The idea

You have private/local data and a small, capable **local model** (served by
[`inference-server`](https://github.com/millrace/mojo-backend), the pure-Mojo
local LLM engine). The local model is good enough to reason over your data, but
some tasks need a frontier model's code-generation ability.

Rather than ship the data to the frontier model, headgate flips the
relationship: **the remote model is treated as an untrusted code generator, not
a data processor.** It sees only the *shape* of your data (a sanitized schema)
and writes code. That code runs **locally**, in a sandbox, against the real
data. Results stay local. The data never crosses the gate.

```
            ┌──────────────────────── headgate ─────────────────────────┐
            │  orchestrator · remote codegen client · schema sanitizer · │
            │  egress guard · code sandbox (containment)                 │
            └──────┬──────────────────────────────────────────┬─────────┘
                   │ OpenAI API (reason over data)             │ codegen request
                   ▼                                           ▼
            inference-server                              remote frontier model
          (local model, on-device)                       (untrusted; code only)
                   │ runs generated code ▼
                   │                 [ sandbox · network = deny ]
                   └──────────── private / local data ─────────┘
```

## Two execution roles (don't conflate them)

| role | executes | who |
|---|---|---|
| **model runner** | the local *model* (inference) | `inference-server` — exists today, OpenAI API |
| **code runner** | the remote model's generated *code* over private data | the **sandbox inside headgate** |

`inference-server` stays harness-agnostic: it is just an OpenAI-compatible
inference server. The seam between it and headgate is the OpenAI API, so anyone
can run `inference-server` under a harness of their choice, or point headgate at
a different local engine.

## Threat model: the careful SaaS provider

headgate v1 defends against an **honest-but-careless** remote provider — one
that won't deliberately smuggle data out, but whose generated code might
*accidentally* leak it (e.g. a stray `requests.post` to a telemetry endpoint, or
a stack trace that echoes a private value back into the next prompt).

That model lets us skip the expensive paranoia (covert timing/size channels,
human-in-the-loop on every byte) and concentrate everything on two chokepoints:

1. **A sandbox that can't phone home** — network denied, read-only scoped
   filesystem, resource limits, a tiny capability allowlist.
2. **An egress guard** — every payload bound for the remote model passes through
   one filter that redacts and *tripwires* on real-data fingerprints (and
   canary tokens seeded into the real data only).

Out of scope for v1: a genuinely adversarial provider trying to exfiltrate
through covert channels. That's a later, harder threat model.

## Two guarantees

- **Containment** (owned by the sandbox): generated code cannot reach the
  network or escape its scope; its output is captured, never self-emitted.
- **Confidentiality** (owned by headgate): nothing sent to the remote model
  contains real data — enforced by schema sanitization + the egress guard, and
  by debugging against *synthetic* data shaped like the real schema, with the
  real data touched only on a final run whose raw output never loops back.

## Design principles

- **Mechanism vs. policy.** `inference-server` (local inference) and the sandbox
  (containment) are mechanism. headgate is confidentiality *policy* on top.
- **Code is the interface** between the capable-but-untrusted party and the
  private party — not data.
- **Sanitize the schema, not just the values.** Column/table names can leak on
  their own; headgate aliases them, mapping real names back locally.
- **No silent leaks.** The egress guard fails closed; any real-data span or
  canary on the outbound path blocks the send.

## Components

- **orchestrator** — owns user intent and data handles; drives the
  synthetic-debug → real-run loop; decides what (if anything) returns to remote.
- **remote codegen client** — talks to the frontier model (Claude API); sends
  spec + sanitized schema + synthetic samples; receives code + a capability
  manifest.
- **schema sanitizer** — derives the schema, aliases sensitive names, and
  synthesizes fake sample rows that match it.
- **egress guard** — the single outbound chokepoint: fingerprint tripwire +
  canary detection + PII redaction; fails closed.
- **code sandbox** — executes generated code under a deny-network policy with a
  small capability broker; captures results/logs locally.

## Layout

```
README.md / PRIOR-ART.md / SPIKE.md   design intent · prior-art survey · sandbox spike
pixi.toml                             Mojo nightly + flare/minja2 wiring; `pixi run spike`
sandbox/headgate.sb.template          PROVEN Seatbelt confinement profile
sandbox/spike.sh                      6/6-passing containment proof (no toolchain needed)
src/egress.mojo                       EgressGuard — outbound confidentiality chokepoint
src/schema.mojo                       SchemaSanitizer — alias names + synthetic samples
src/transport.mojo                    Local/Remote clients (remote gated by EgressGuard)
src/sandbox.mojo + src/broker.mojo    containment runner + capability allowlist
src/orchestrator.mojo                 core loop: synthetic-debug → real-run
src/headgate.mojo                     composition root / demo
```

## Status

Early, but past "just a doc":

- **Sandbox spike: done and verified.** The containment boundary is proven on
  macOS / Apple Silicon — `pixi run spike` (or `./sandbox/spike.sh`) passes 6/6
  checks: network egress denied, writes scoped, `$HOME` reads denied. See
  [SPIKE.md](SPIKE.md).
- **First vertical slice: compiles + runs.** `src/sandbox.mojo` is filled in
  end-to-end — it renders the Seatbelt profile, canonicalizes paths (`realpath`),
  execs under `sandbox-exec`, and captures exit code + output, all from Mojo.
  `pixi run sandbox-demo` (or `pixi run build`) builds `build/sandbox-demo`, which
  re-verifies containment from Mojo: in-scope read works, out-of-scope read and
  network egress are denied.
- **Whole graph compiles + runs.** All `src/` layers (egress, schema, transport,
  broker, orchestrator, headgate) are converted to current Mojo syntax and
  `pixi run build-full` builds `build/headgate`, which runs the full flow
  end-to-end (layers above the sandbox are stubs returning empty; the sandbox is
  real). The real behavior (flare transport, schema introspection, capability
  shim) is where the TODOs are.
- **Toolchain: pinned to `1.0.0b2.dev2026053106`** — the org/flare nightly.
  flare's upstream deps (`json`, `mozz`) have no tags compatible with a newer
  nightly, so the whole org is effectively pinned here; headgate matches so
  `-I ../flare` resolves against the same toolchain.
- **Mojo conventions:** `.agents/skills/mojo-syntax` (copied from `mojo-backend`)
  is the source of truth for current Mojo syntax — follow it over pretrained
  knowledge.
