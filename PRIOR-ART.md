# Prior art: agent harnesses, and what headgate borrows

We surveyed three existing AI coding/agent harnesses — **Cursor**, **opencode**,
and **pi** — to learn from their architectures before committing to headgate's.
This records what we found and what we adopt.

The headline conclusion: **none of them solve headgate's actual problem.** They
all assume *the model is trusted and sending data to it is fine*. headgate
inverts that trust boundary. So we copy **mechanics, not data-flow** — which is
also why headgate is a new repo, not a fork of any of these.

## The three on a spectrum

Read left → right, they go **heavy / proprietary / cloud-routed → server-first /
middleweight → minimal / local-first**.

| axis | **Cursor** | **opencode** | **pi** |
|---|---|---|---|
| loop shape | hierarchical planner→worker→judge, recursive sub-agents | server-first; single streaming loop + spawnable sub-agents (`task` tool) | minimal single ReAct loop; **no** sub-agents/plan mode by design |
| where the model lives | remote only; **always routed through Cursor's backend** (even with your own key) | provider-agnostic (Vercel AI SDK); direct to provider; no middleman | provider-agnostic (`pi-ai`); direct to provider; no middleman |
| local OpenAI seam | not a first-class path | **first-class** (`@ai-sdk/openai-compatible` + `baseURL`) | **first-class** (Ollama / OpenAI-compatible) |
| who owns the system prompt | Cursor (server-side) | host (composed in `system.ts`/`prompt.ts`) | host; deliberately tiny (~300 words) |
| sandbox | **real OS sandbox** (Seatbelt / Landlock+seccomp / WSL2), network-deny default | **none** — in-process child procs; only allow/ask/deny rules + path confinement | **none by design** — "no in-process security"; expects an external container jail |
| tools | rich built-ins + full MCP (local+remote) | rich built-ins + MCP | 4 tools (`read/write/edit/bash`), **no MCP** |
| architecture style | heavy, proprietary, cloud-coupled | middleweight, server-first, OpenAPI/SDK, Effect/TS | minimalist, cleanly layered monorepo |

## Per-harness notes

### Cursor
- **Counter-example on data flow.** Code/context is routed through Cursor's own
  backend for final prompt building — *confirmed even when you bring your own
  provider API key.* Privacy is **contractual** (zero-data-retention agreements
  with providers), not **architectural**. If "data never leaves the machine" is a
  hard constraint, Cursor's pattern is disqualified by construction.
- **Retrieval pattern worth knowing:** store only embeddings + obfuscated
  path/line coordinates remotely, resolve the real code locally at query time.
  Good indirection — but only private if the embeddings are *also* computed
  locally, which Cursor's aren't.
- **Sandbox is real and documented:** Seatbelt/`sandbox-exec` (macOS),
  Landlock+seccomp (Linux), WSL2 (Windows); network blocked by default, FS scoped
  to the workspace. Cursor's own caveat: all modes are **best-effort, bypassable.**
- Layered approval pipeline (allowlist → sandbox → LLM-classifier). The
  LLM-classifier tier is a convenience filter, **not** a security boundary.

Sources: cursor.com/data-use, cursor.com/blog/agent-sandboxing,
cursor.com/docs/agent/security, simonwillison.net/2025/May/11/cursor-security/

### opencode
- **Server-first** headless HTTP server (OpenAPI 3.1 + SDK) with thin swappable
  clients (TUI, web, IDE). Effect/TS throughout. The AI SDK owns the agentic tool
  loop; opencode is the event/persistence/permission layer around it.
- **Local OpenAI-compatible models are first-class** via
  `@ai-sdk/openai-compatible` + `baseURL` — documented pointing at a local server.
  This is exactly headgate's `inference-server` seam, already proven.
- **No OS sandbox.** Tools (incl. `bash`) run in-process with host privileges;
  isolation is only declarative allow/ask/deny rules + an `external_directory`
  path boundary a shell command can escape.
- **Silent egress paths** even with a local model: remote MCP (HTTP/SSE),
  `webfetch`/`websearch`, http(s) instruction-URL fetching, optional hosted
  gateway, provider telemetry headers.

Sources: github.com/sst/opencode (read at commit 31c099b), opencode.ai/docs

### pi (Mario Zechner / `earendil-works/pi`)
- **Minimal single ReAct loop**, 4 tools (`read/write/edit/bash`), **no MCP**,
  ~300-word system prompt. Parallelism = spawn another `pi` via `bash`.
- **"No in-process security" thesis:** once an agent can read + execute +
  network, in-process security is infeasible — so isolate it **externally**
  (container with `--network none`, read-only mounts, tmpfs). This *is* headgate's
  containment model.
- **Cleanly layered monorepo:** `pi-ai` (provider transport) / `pi-agent-core`
  (loop) / `pi-coding-agent` (CLI/sessions/skills) / `pi-tui`. The isolated
  transport layer is the natural egress-guard chokepoint.
- Provider-agnostic, **no hosted middleman**; local models via Ollama / any
  OpenAI-compatible endpoint; mid-session model switching.
- Minimal context surface = fewer accidental leaks (every byte in context is a
  byte sent remote).

Sources: github.com/earendil-works/pi,
mariozechner.at/posts/2025-11-30-pi-coding-agent/

## What each validates about headgate's design

- **Host owns the system prompt** — all three do this (confirms our model).
- **Local OpenAI-compatible server as a `baseURL`** — first-class in both
  opencode and pi; that's the `inference-server` seam we drew, proven twice.

## Decision: what headgate adopts

**Base on pi's philosophy** — it's the closest fit to headgate's
containment/confidentiality split:

1. It already assumes our **containment model** (isolate externally; no
   in-process security).
2. Its **layered separation** gives us the egress-guard chokepoint for free — one
   transport seam to enforce schema-sanitization + fingerprint tripwire.
3. **Minimal context surface** is a privacy feature, not just aesthetics.

**Borrow from Cursor: the sandbox, wholesale.** pi and opencode have none — the
exact piece headgate's code-runner depends on. Take Seatbelt / Landlock+seccomp /
WSL2 with **network-deny by default, FS scoped to workspace**. Since Cursor warns
these are best-effort/bypassable, go one notch stronger for an actual guarantee:
**microVM + an egress allowlist permitting only the remote model API.** Skip the
LLM-classifier approval tier — it's not a privacy boundary.

**Borrow from opencode: the server-first API surface — later, if needed.** Its
headless-server + OpenAPI/SDK is the cleanest way to let multiple clients (and the
local-model orchestrator) drive the harness. Worth it only when headgate needs to
be embeddable/driveable; not worth opencode's heavy Effect dependency up front.
Its allow/ask/deny permission-event protocol is a nice UX pattern to lift without
the framework.

**Reject from all three: open egress paths.** headgate must **default-deny every
outbound channel except the one model API**, and gate MCP / webfetch /
instruction-fetching — these are on-by-config elsewhere and must be
off-by-default here.

### One-line summary

> pi-shaped core (minimal loop, layered, egress guard at the transport seam,
> externally isolated) + Cursor-grade sandbox for the code-runner + opencode's
> server API as a later option.
