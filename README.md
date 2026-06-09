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
DOCUMENT-MODE.md                      design: arbitrary files (PDF/docx/…), not just CSV
pixi.toml                             Mojo nightly + flare/minja2 wiring; `pixi run spike`
sandbox/headgate.sb.template          PROVEN Seatbelt confinement profile
sandbox/spike.sh                      6/6-passing containment proof (no toolchain needed)
src/egress.mojo                       EgressGuard — outbound confidentiality chokepoint
src/schema.mojo                       SchemaSanitizer — alias names + synthetic samples
src/transport.mojo                    Local/Remote clients (remote gated by EgressGuard)
src/sandbox.mojo + src/broker.mojo    containment runner + capability allowlist
src/orchestrator.mojo                 core loop: synthetic-debug → real-run
src/headgate.mojo                     composition root / CLI + REPL
web/                                  headgate for the web — local React chat UI
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
- **Real CSV schema sanitizer + egress guard.** `pixi run schema-demo` (type
  inference + aliasing + dealias) and `pixi run egress-test` (3/3: clean passes,
  fingerprint + canary blocked — confidentiality enforced, not nominal).
- **Generated-code pipeline + full thin slice.** `pixi run pipeline-demo` compiles
  generated Mojo and runs it in the sandbox (benign computes over real data;
  malicious `$HOME` reader contained). `pixi run e2e-demo` runs the whole flow —
  sanitize → guarded codegen (mock) → dealias + inject path → compile + run in
  sandbox → result (`ROW_COUNT= 3`).
- **Transport over flare (pure Mojo).** `src/transport.mojo` uses flare's
  `HttpClient` + json (no curl/python). `LocalClient` (OpenAI/plain-HTTP) is
  runtime-verified — `pixi run local-probe` → `LOCAL HTTP OK`. `RemoteClient`
  (Anthropic Messages API, HTTPS) compiles; runtime needs `ANTHROPIC_API_KEY`.
  flare's FFI shims are built into this env by the `flare-ffi` task.
- **Remote-API budget with local fallback.** `HEADGATE_REMOTE_TOKEN_BUDGET` caps
  spend on the frontier model (tokens charged from the API's `usage`); once
  depleted, codegen **and** compile/runtime fixes route to the LOCAL model
  (trusted + free, lower quality) instead of failing. `-1`/unset = unlimited,
  `0` = always-local, `N` = N tokens then local. `pixi run budget-test` (unit) +
  `pixi run budget-route-demo` (budget=0 → local codegen → `ROW_COUNT= 3`).
- **Toolchain: pinned to `1.0.0b2.dev2026060706`** — the org nightly. The
  flare + json sibling forks are ported to it (json CPU-only; mozz disabled), so
  `-I ../flare -I ../json` resolve against the same toolchain.
- **Mojo conventions:** `.agents/skills/mojo-syntax` (copied from `mojo-backend`)
  is the source of truth for current Mojo syntax — follow it over pretrained
  knowledge.

## Configuration

headgate reads `~/.config/headgate/config.json` (override the path with
`HEADGATE_CONFIG`). It's parsed with the `json` fork (`src/settings.mojo`). All
keys are optional; see [`config.example.json`](config.example.json):

| key | default | env override |
|---|---|---|
| `local_url` | `http://127.0.0.1:8000/v1` | `HEADGATE_LOCAL_URL` |
| `local_model` | `local` | `HEADGATE_LOCAL_MODEL` |
| `remote_base_url` | `https://api.anthropic.com/v1` | `ANTHROPIC_BASE_URL` |
| `remote_model` | `claude-sonnet-4-6` | `HEADGATE_MODEL` |
| `remote_token_budget` | `-1` (unlimited) | `HEADGATE_REMOTE_TOKEN_BUDGET` |
| `anthropic_api_key` | `""` | `ANTHROPIC_API_KEY` *(env preferred for secrets)* |
| `mock` | `false` | `HEADGATE_MOCK` (set = true) |
| `use_local_summary` | `false` | `HEADGATE_LOCAL` (set = true) |

**Precedence: environment variable > config file > built-in default** — so
existing env-based workflows are unchanged, and the file is just a default layer.
